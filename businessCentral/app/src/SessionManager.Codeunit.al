// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License. See LICENSE in the project root for license information.
namespace Zig.ADLSE;

using System.Environment;

codeunit 11007173 "ADLSE Session Manager"
{
    Access = Internal;

    var
        LastProcessedTableID: Integer;
        ConcatendatedStringLbl: Label '%1,%2', Locked = true;
        CouldNotStartSessionErr: Label 'The export was queued, but no background session could be started for it after %1 attempts. It will be retried with the next export.', Comment = '%1 = number of attempts';
        TableNoLongerConfiguredErr: Label 'The export was queued, but the table is no longer configured for export.';
        CouldNotStartPendingTableErr: Label 'The export was queued, but its export session could not be started after %1 attempts. It will be retried with the next export. Last error: %2', Comment = '%1 = number of attempts, %2 = error text';

    /// <summary>Clears the pending tables queue of the current company.</summary>
    procedure Init()
    begin
        ClearPendingTables();
        Commit();
    end;

    procedure StartExport(TableID: Integer; EmitTelemetry: Boolean): Boolean
    begin
        // A queued table is started by the processing of the pending tables queue, also when another export started meanwhile.
        if IsTablePending(TableID) then
            exit(false);

        // if the last run failed, ensure that you run again, even though there may be no data differences.
        // Also force the very first run for Open Mirroring, since an empty table would otherwise never get a session
        // (DataChangesExist stays false forever), and would never receive its initial (header-only) snapshot file.
        exit(StartExport(TableID, false, LastRunFailed(TableID, EmitTelemetry) or NeverRunOnOpenMirroring(TableID), EmitTelemetry, 0));
    end;

    /// <summary>Starts the export of a table taken from the pending tables queue.</summary>
    internal procedure StartPendingExport(TableID: Integer; EmitTelemetry: Boolean; StartAttempts: Integer): Boolean
    begin
        exit(StartExport(TableID, true, true, EmitTelemetry, StartAttempts));
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Table", 'r')]
    local procedure StartExport(TableID: Integer; ExportWasPending: Boolean; ForceExport: Boolean; EmitTelemetry: Boolean; StartAttempts: Integer) Started: Boolean
    var
        ADLSETable: Record "ADLSE Table";
        ADLSESetup: Record "ADLSE Setup";
        ADLSERun: Record "ADLSE Run";
        ADLSEExecution: Codeunit "ADLSE Execution";
        ADLSEUtil: Codeunit "ADLSE Util";
        CustomDimensions: Dictionary of [Text, Text];
        NewSessionID: Integer;
        SessionTimeout: Duration;
    begin
        if ForceExport or DataChangesExist(TableID) then begin
            if not ADLSETable.Get(TableID) then begin
                if ExportWasPending then
                    ADLSERun.RegisterFailed(TableID, TableNoLongerConfiguredErr, false);
                exit;
            end;

            ADLSESetup.GetSingleton();
            if ADLSESetup."Export Company Database Tables" <> '' then
                if (not ADLSEUtil.IsTablePerCompany(TableID)) then
                    if (ADLSESetup."Export Company Database Tables" <> CompanyName()) then begin
                        if ExportWasPending then
                            ADLSERun.RegisterFailed(TableID, TableNoLongerConfiguredErr, false);
                        exit;
                    end;

            // Register the run as in process right away, so that a client polling the runs never
            // sees the result of a previous export for a table that is still queued or starting.
            ADLSERun.RegisterQueued(TableID);
            Commit(); // release the lock on the run before the new session picks it up

            SessionTimeout := 1000 * 60 * 60 * 24; // 24 hours

            Started := Session.StartSession(NewSessionID, Codeunit::"ADLSE Wrapper Execute", CompanyName(), ADLSETable, SessionTimeout);
            CustomDimensions.Add('Entity', ADLSEUtil.GetTableCaption(TableID));
            CustomDimensions.Add('ExportWasPending', Format(ExportWasPending));
            if Started then begin
                CustomDimensions.Add('SessionId', Format(NewSessionID));
                if EmitTelemetry then
                    ADLSEExecution.Log('ADLSE-002', 'Export session created', Verbosity::Normal, CustomDimensions);
            end else begin
                CustomDimensions.Add('StartAttempts', Format(StartAttempts));
                if EmitTelemetry then
                    ADLSEExecution.Log('ADLSE-025', 'Session.StartSession() failed', Verbosity::Warning, CustomDimensions);

                if StartAttempts >= GetMaxStartAttempts() then
                    GiveUpPendingTable(TableID, StartAttempts, CustomDimensions)
                else
                    PushToPendingTables(TableID, StartAttempts);
            end;
        end else
            if EmitTelemetry then begin
                CustomDimensions.Add('Entity', ADLSEUtil.GetTableCaption(TableID));
                ADLSEExecution.Log('ADLSE-024', 'No changes to be exported.', Verbosity::Normal, CustomDimensions);
            end;

        OnAfterStartExport(TableID, ExportWasPending, ForceExport, EmitTelemetry, Started);
    end;

    local procedure DataChangesExist(TableID: Integer): Boolean
    var
        ADLSETableLastTimestamp: Record "ADLSE Table Last Timestamp";
        ADLSEExecute: Codeunit "ADLSE Execute";
        UpdatedLastTimestamp: BigInteger;
        DeletedLastEntryNo: BigInteger;
    begin
        UpdatedLastTimestamp := ADLSETableLastTimestamp.GetUpdatedLastTimestamp(TableID);
        DeletedLastEntryNo := ADLSETableLastTimestamp.GetDeletedLastEntryNo(TableID);

        if ADLSEExecute.UpdatedRecordsExist(TableID, UpdatedLastTimestamp) then
            exit(true);
        if ADLSEExecute.DeletedRecordsExist(TableID, DeletedLastEntryNo) then
            exit(true);
    end;

    local procedure LastRunFailed(TableID: Integer; EmitTelemetry: Boolean) Result: Boolean
    var
        ADLSERun: Record "ADLSE Run";
        ADLSEUtil: Codeunit "ADLSE Util";
        ADLSEExecution: Codeunit "ADLSE Execution";
        CustomDimensions: Dictionary of [Text, Text];
        Status: Enum "ADLSE Run State";
        StartedAt: DateTime;
        Error: Text[2048];
    begin
        ADLSERun.GetLastRunDetails(TableID, Status, StartedAt, Error);
        Result := Status = "ADLSE Run State"::Failed;
        if Result and EmitTelemetry then begin
            CustomDimensions.Add('Entity', ADLSEUtil.GetTableCaption(TableID));
            ADLSEExecution.Log('ADLSE-027', 'Last run failed.', Verbosity::Normal, CustomDimensions);
        end;
    end;

    local procedure NeverRunOnOpenMirroring(TableID: Integer): Boolean
    var
        ADLSESetup: Record "ADLSE Setup";
        ADLSERun: Record "ADLSE Run";
        Status: Enum "ADLSE Run State";
        StartedAt: DateTime;
        Error: Text[2048];
    begin
        ADLSESetup.GetSingleton();
        if ADLSESetup.GetStorageType() <> ADLSESetup."Storage Type"::"Open Mirroring" then
            exit(false);

        ADLSERun.GetLastRunDetails(TableID, Status, StartedAt, Error);
        exit(Status = "ADLSE Run State"::None);
    end;

    /// <summary>
    /// Starts export sessions for the queued tables until the queue is empty or no further
    /// session can be started, and makes sure a retry is scheduled for whatever is left.
    /// </summary>
    procedure StartExportFromPendingTables()
    begin
        DrainPendingTables(false);
        EnsurePendingQueueProcessing();
    end;

    /// <summary>
    /// Starts export sessions for the queued tables until the queue is empty or no further session can be started.
    /// Pending tables are always force-exported: their changes were already detected when they were queued.
    /// </summary>
    /// <param name="CountFailedAttempts">Count a failure to start a session towards giving up on the table.</param>
    /// <returns>Whether at least one export session was started.</returns>
    internal procedure DrainPendingTables(CountFailedAttempts: Boolean) AnyStarted: Boolean
    var
        ADLSESetup: Record "ADLSE Setup";
        ADLSETable: Record "ADLSE Table";
        ADLSEStartTableExport: Codeunit "ADLSE Start Table Export";
        ADLSEExecution: Codeunit "ADLSE Execution";
        CustomDimensions: Dictionary of [Text, Text];
        TableID: Integer;
        ClaimedAttempts: Integer;
        StartAttempts: Integer;
    begin
        if not HasPendingTables() then
            exit(false);

        ADLSESetup.GetSingleton();
        if ADLSESetup."Emit telemetry" then begin
            CustomDimensions.Add('PendingTables', Concatenate(GetPendingTablesList()));
            ADLSEExecution.Log('ADLSE-026', 'Export from pending tables starting', Verbosity::Normal, CustomDimensions);
        end;

        while ClaimNextPendingTable(TableID, ClaimedAttempts) do begin
            StartAttempts := ClaimedAttempts;
            if CountFailedAttempts then
                StartAttempts += 1;

            // Start each table in isolation: the table was already taken from the queue, so an error
            // must not lose it, nor stop the start of the other tables.
            Clear(ADLSEStartTableExport);
            ADLSEStartTableExport.SetEmitTelemetry(ADLSESetup."Emit telemetry");
            ADLSEStartTableExport.SetPendingStart(StartAttempts);
            ADLSETable.Init();
            ADLSETable."Table ID" := TableID;
            if not ADLSEStartTableExport.Run(ADLSETable) then begin
                RequeueAfterStartError(TableID, ClaimedAttempts + 1);
                exit;
            end;

            if ADLSEStartTableExport.WasStarted() then begin
                AnyStarted := true;
                LastProcessedTableID := TableID;
            end else
                if IsTablePending(TableID) then
                    exit // no session available right now; the table went back into the queue
                else
                    LastProcessedTableID := TableID; // the table is not exported, so the export may be finished
        end;
    end;

    /// <summary>
    /// Puts a table back into the queue after an error while starting its export, or gives up on it
    /// when it failed to start too often.
    /// </summary>
    local procedure RequeueAfterStartError(TableID: Integer; StartAttempts: Integer)
    var
        ADLSERun: Record "ADLSE Run";
        ADLSEExecution: Codeunit "ADLSE Execution";
        ADLSEUtil: Codeunit "ADLSE Util";
        CustomDimensions: Dictionary of [Text, Text];
        ErrorText: Text;
    begin
        ErrorText := GetLastErrorText();
        CustomDimensions.Add('Entity', ADLSEUtil.GetTableCaption(TableID));
        CustomDimensions.Add('StartAttempts', Format(StartAttempts));
        CustomDimensions.Add('Error text', ErrorText);
        CustomDimensions.Add('Error stack', GetLastErrorCallStack());
        ClearLastError();
        ADLSEExecution.Log('ADLSE-057', 'Could not start the export of a queued table.', Verbosity::Warning, CustomDimensions);

        if StartAttempts >= GetMaxStartAttempts() then begin
            ADLSERun.RegisterFailed(TableID, StrSubstNo(CouldNotStartPendingTableErr, StartAttempts, ErrorText), true);
            Commit();
            LastProcessedTableID := TableID;
        end else
            PushToPendingTables(TableID, StartAttempts);
    end;

    /// <summary>
    /// Schedules a task to process the pending tables when tables are queued but no running
    /// export session is left that would pick them up when it finishes.
    /// </summary>
    internal procedure EnsurePendingQueueProcessing()
    begin
        SchedulePendingStarterIfNeeded(false);
    end;

    local procedure SchedulePendingStarterIfNeeded(CalledFromStarterTask: Boolean)
    var
        ADLSESetup: Record "ADLSE Setup";
        ADLSECurrentSession: Record "ADLSE Current Session";
        ADLSEExecution: Codeunit "ADLSE Execution";
        NotBefore: DateTime;
    begin
        if not HasPendingTables() then
            exit;
        // The active export sessions process the queue when they finish. The starter task schedules its successor
        // regardless: a session finishing before the starter task ends would still see it as scheduled and skip.
        if not CalledFromStarterTask then
            if ADLSECurrentSession.AreAnySessionsActive() then
                exit;
        if IsPendingStarterScheduled(CalledFromStarterTask) then
            exit;

        if not TaskScheduler.CanCreateTask() then begin
            ADLSEExecution.Log('ADLSE-054', 'Tables are pending for export, but no task can be scheduled to start them.', Verbosity::Warning);
            exit;
        end;

        NotBefore := CurrentDateTime() + GetPendingRetryDelay();
        TaskScheduler.CreateTask(Codeunit::"ADLSE Pending Export Starter", 0, true, CompanyName(), NotBefore);

        ADLSESetup.GetSingleton();
        if ADLSESetup."Emit telemetry" then
            ADLSEExecution.Log('ADLSE-052', 'Scheduled a task to start the export of the pending tables.', Verbosity::Normal);
    end;

    /// <summary>
    /// Checks whether a task is already scheduled to process the pending tables, so that no duplicate
    /// tasks pile up. Overdue tasks still waiting for a free background session are counted as well.
    /// A task stays scheduled while it runs, so the running starter task excludes itself to be able to
    /// schedule its successor.
    /// </summary>
    local procedure IsPendingStarterScheduled(CalledFromStarterTask: Boolean): Boolean
    var
        ScheduledTask: Record "Scheduled Task";
    begin
        if not ScheduledTask.ReadPermission() then
            exit(false);
        ScheduledTask.SetRange("Run Codeunit", Codeunit::"ADLSE Pending Export Starter");
        ScheduledTask.SetRange(Company, CompanyName());
        if CalledFromStarterTask then
            exit(ScheduledTask.Count() > 1);
        exit(not ScheduledTask.IsEmpty());
    end;

    internal procedure ProcessPendingTablesFromTask()
    var
        ADLSETable: Record "ADLSE Table";
        ADLSECurrentSession: Record "ADLSE Current Session";
        ADLSEExecute: Codeunit "ADLSE Execute";
        ADLSEUtil: Codeunit "ADLSE Util";
    begin
        if not HasPendingTables() then
            exit;

        // Another session is starting an export or processing the queue; it schedules a retry if needed.
        if not ADLSECurrentSession.TryReserveExport() then
            exit;
        Commit();

        // A failure to start a session only counts towards giving up when no export session of
        // our own occupies the background sessions.
        DrainPendingTables(not ADLSECurrentSession.AreAnySessionsActive());
        ADLSECurrentSession.ReleaseExport();
        Commit();
        SchedulePendingStarterIfNeeded(true);

        // Export sessions that ended while the queue was reserved, including the ones just started, left the
        // export finished notification to this session. The check covers the sessions still running.
        // Without a processed table, only the event that all exports are finished is raised.
        if LastProcessedTableID <> 0 then
            if ADLSETable.Get(LastProcessedTableID) then begin
                ADLSEExecute.NotifyExportFinishedIfDone(ADLSETable, ADLSEUtil.GetTableCaption(LastProcessedTableID));
                exit;
            end;
        Clear(ADLSETable);
        ADLSEExecute.NotifyExportFinishedIfDone(ADLSETable, '');
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'r')]
    internal procedure HasPendingTables(): Boolean
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
    begin
        ADLSEPendingTable.SetRange("Company Name", CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")));
        exit(not ADLSEPendingTable.IsEmpty());
    end;

    /// <summary>
    /// Fails the runs of the queued tables and clears the queue of the current company. Used when
    /// the queue is left over from an earlier export that is no longer running.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'rd')]
    internal procedure AbandonPendingTables(Reason: Text)
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
        ADLSERun: Record "ADLSE Run";
    begin
        ADLSEPendingTable.SetRange("Company Name", CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")));
        if ADLSEPendingTable.FindSet(false) then
            repeat
                ADLSERun.RegisterFailed(ADLSEPendingTable."Table ID", Reason, false);
            until ADLSEPendingTable.Next() = 0;
        ADLSEPendingTable.DeleteAll(false);
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'd')]
    internal procedure ClearPendingTables()
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
    begin
        ADLSEPendingTable.SetRange("Company Name", CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")));
        ADLSEPendingTable.DeleteAll(false);
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'd')]
    internal procedure ClearPendingTablesAllCompanies()
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
    begin
        ADLSEPendingTable.DeleteAll(false);
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'rd')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Run", 'rim')]
    internal procedure RemoveFromPendingTables(TableID: Integer)
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
        ADLSERun: Record "ADLSE Run";
    begin
        if ADLSEPendingTable.Get(CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")), TableID) then begin
            ADLSEPendingTable.Delete(false);
            // No session exports the table anymore, so its queued run would otherwise stay in process.
            ADLSERun.RegisterFailed(TableID, TableNoLongerConfiguredErr, false);
        end;
    end;

    /// <summary>
    /// Takes the oldest table from the queue. The row is locked and deleted in its own
    /// transaction, so a table can never be claimed by two sessions at the same time.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'rd')]
    local procedure ClaimNextPendingTable(var TableID: Integer; var StartAttempts: Integer): Boolean
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
    begin
        ADLSEPendingTable.ReadIsolation := IsolationLevel::UpdLock;
        ADLSEPendingTable.SetCurrentKey("Company Name", "Queued At");
        ADLSEPendingTable.SetRange("Company Name", CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")));
        if not ADLSEPendingTable.FindFirst() then
            exit(false);

        TableID := ADLSEPendingTable."Table ID";
        StartAttempts := ADLSEPendingTable."Start Attempts";
        if not ADLSEPendingTable.Delete(false) then
            exit(false);
        Commit();
        exit(true);
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'ri')]
    local procedure PushToPendingTables(TableID: Integer; StartAttempts: Integer)
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
    begin
        ADLSEPendingTable."Company Name" := CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name"));
        ADLSEPendingTable."Table ID" := TableID;
        if ADLSEPendingTable.Find() then
            exit;
        ADLSEPendingTable."Queued At" := CurrentDateTime();
        ADLSEPendingTable."Start Attempts" := StartAttempts;
        if ADLSEPendingTable.Insert(false) then;
        Commit();
    end;

    local procedure GiveUpPendingTable(TableID: Integer; StartAttempts: Integer; CustomDimensions: Dictionary of [Text, Text])
    var
        ADLSERun: Record "ADLSE Run";
        ADLSEExecution: Codeunit "ADLSE Execution";
    begin
        ADLSERun.RegisterFailed(TableID, StrSubstNo(CouldNotStartSessionErr, StartAttempts), true);
        Commit();
        LastProcessedTableID := TableID;
        ADLSEExecution.Log('ADLSE-053', 'Gave up starting the export session for a queued table.', Verbosity::Error, CustomDimensions);
    end;

    /// <summary>
    /// Checks whether an export session was started recently for a table of the current company, but has
    /// not registered itself yet. Such a session is not yet visible as an active session.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Run", 'r')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'r')]
    internal procedure AnyExportSessionStarting(): Boolean
    var
        ADLSERun: Record "ADLSE Run";
        ADLSECurrentSession: Record "ADLSE Current Session";
    begin
        ADLSERun.SetRange("Company Name", CompanyName());
        ADLSERun.SetRange(State, "ADLSE Run State"::InProcess);
        ADLSERun.SetFilter(Started, '>=%1', CurrentDateTime() - GetSessionStartGracePeriod());
        ADLSERun.SetLoadFields("Table ID");
        if ADLSERun.FindSet(false) then
            repeat
                if not IsTablePending(ADLSERun."Table ID") then
                    if not ADLSECurrentSession.Get(ADLSERun."Table ID", CompanyName()) then
                        exit(true);
            until ADLSERun.Next() = 0;
        exit(false);
    end;

    local procedure GetSessionStartGracePeriod(): Duration
    begin
        exit(10 * 60 * 1000); // 10 minutes; a session that has not registered itself by then is considered lost
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'r')]
    local procedure IsTablePending(TableID: Integer): Boolean
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
    begin
        exit(ADLSEPendingTable.Get(CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")), TableID));
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'r')]
    local procedure GetPendingTablesList() Tables: List of [Integer]
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
    begin
        ADLSEPendingTable.SetCurrentKey("Company Name", "Queued At");
        ADLSEPendingTable.SetRange("Company Name", CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")));
        ADLSEPendingTable.SetLoadFields("Table ID");
        if ADLSEPendingTable.FindSet(false) then
            repeat
                Tables.Add(ADLSEPendingTable."Table ID");
            until ADLSEPendingTable.Next() = 0;
    end;

    local procedure GetMaxStartAttempts(): Integer
    begin
        exit(10); // with a retry every minute, a table is given up after ~10 minutes without free sessions
    end;

    local procedure GetPendingRetryDelay(): Duration
    begin
        exit(60 * 1000); // 1 minute
    end;

    local procedure Concatenate(Values: List of [Integer]) Result: Text
    var
        Value: Integer;
    begin
        foreach Value in Values do
            if Result = '' then
                Result := Format(Value, 0, 9)
            else
                Result := StrSubstNo(ConcatendatedStringLbl, Result, Value);
    end;

    local procedure DeConcatenate(CommaSeperatedText: Text) Values: List of [Integer]
    var
        TextValues: List of [Text];
        ValueText: Text;
        ValueInt: Integer;
    begin
        TextValues := CommaSeperatedText.Split(',');
        foreach ValueText in TextValues do
            if Evaluate(ValueInt, ValueText) then
                Values.Add(ValueInt);
    end;

    /// <summary>Replaces the pending tables queue of the current company with the given comma-separated table IDs.</summary>
    internal procedure SavePendingTables(Value: Text)
    var
        TableID: Integer;
    begin
        ClearPendingTables();
        foreach TableID in DeConcatenate(Value) do
            PushToPendingTables(TableID, 0);
        Commit();
    end;

    [IntegrationEvent(false, false)]
    local procedure OnAfterStartExport(TableID: Integer; ExportWasPending: Boolean; ForceExport: Boolean; EmitTelemetry: Boolean; var Started: Boolean)
    begin
    end;
}
