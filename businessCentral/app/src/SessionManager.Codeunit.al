// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License. See LICENSE in the project root for license information.
namespace Zig.ADLSE;

codeunit 11007173 "ADLSE Session Manager"
{
    Access = Internal;

    var
        LastGivenUpTableID: Integer;
        ConcatendatedStringLbl: Label '%1,%2', Locked = true;
        CouldNotStartSessionErr: Label 'The export was queued, but no background session could be started for it after %1 attempts. It will be retried with the next export.', Comment = '%1 = number of attempts';
        TableNoLongerConfiguredErr: Label 'The export was queued, but the table is no longer configured for export.';

    /// <summary>Clears the pending tables queue of the current company.</summary>
    procedure Init()
    begin
        ClearPendingTables();
        Commit();
    end;

    procedure StartExport(TableID: Integer; EmitTelemetry: Boolean): Boolean
    begin
        // if the last run failed, ensure that you run again, even though there may be no data differences.
        // Also force the very first run for Open Mirroring, since an empty table would otherwise never get a session
        // (DataChangesExist stays false forever), and would never receive its initial (header-only) snapshot file.
        exit(StartExport(TableID, false, LastRunFailed(TableID, EmitTelemetry) or NeverRunOnOpenMirroring(TableID), EmitTelemetry, 0));
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
                    if (ADLSESetup."Export Company Database Tables" <> CompanyName()) then
                        exit;

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
        ADLSEExecution: Codeunit "ADLSE Execution";
        CustomDimensions: Dictionary of [Text, Text];
        TableID: Integer;
        StartAttempts: Integer;
    begin
        if not HasPendingTables() then
            exit(false);

        ADLSESetup.GetSingleton();
        if ADLSESetup."Emit telemetry" then begin
            CustomDimensions.Add('PendingTables', Concatenate(GetPendingTablesList()));
            ADLSEExecution.Log('ADLSE-026', 'Export from pending tables starting', Verbosity::Normal, CustomDimensions);
        end;

        while ClaimNextPendingTable(TableID, StartAttempts) do begin
            if CountFailedAttempts then
                StartAttempts += 1;
            if StartExport(TableID, true, true, ADLSESetup."Emit telemetry", StartAttempts) then
                AnyStarted := true
            else
                if IsTablePending(TableID) then
                    exit; // no session available right now; the table went back into the queue
        end;
    end;

    /// <summary>
    /// Schedules a task to process the pending tables when tables are queued but no running
    /// export session is left that would pick them up when it finishes.
    /// </summary>
    internal procedure EnsurePendingQueueProcessing()
    var
        ADLSESetup: Record "ADLSE Setup";
        ADLSECurrentSession: Record "ADLSE Current Session";
        ADLSEExecution: Codeunit "ADLSE Execution";
        NotBefore: DateTime;
    begin
        if not HasPendingTables() then
            exit;
        if ADLSECurrentSession.AreAnySessionsActive() then
            exit; // the active export sessions process the queue when they finish

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

    internal procedure ProcessPendingTablesFromTask()
    var
        ADLSETable: Record "ADLSE Table";
        ADLSECurrentSession: Record "ADLSE Current Session";
        ADLSEExecute: Codeunit "ADLSE Execute";
        ADLSEUtil: Codeunit "ADLSE Util";
    begin
        if not HasPendingTables() then
            exit;

        // A failure to start a session only counts towards giving up when no export session of
        // our own occupies the background sessions.
        DrainPendingTables(not ADLSECurrentSession.AreAnySessionsActive());
        EnsurePendingQueueProcessing();

        if LastGivenUpTableID <> 0 then
            if ADLSETable.Get(LastGivenUpTableID) then
                ADLSEExecute.NotifyExportFinishedIfDone(ADLSETable, ADLSEUtil.GetTableCaption(LastGivenUpTableID));
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
    internal procedure RemoveFromPendingTables(TableID: Integer)
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
    begin
        if ADLSEPendingTable.Get(CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")), TableID) then
            ADLSEPendingTable.Delete(false);
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
        LastGivenUpTableID := TableID;
        ADLSEExecution.Log('ADLSE-053', 'Gave up starting the export session for a queued table.', Verbosity::Error, CustomDimensions);
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
