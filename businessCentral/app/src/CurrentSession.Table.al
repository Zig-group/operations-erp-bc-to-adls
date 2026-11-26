// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License. See LICENSE in the project root for license information.
namespace Zig.ADLSE;

using System.Environment;

#pragma warning disable LC0015
table 11007160 "ADLSE Current Session"
#pragma warning restore
{
    Access = Internal;
    Caption = 'ADLSE Current Session';
    DataClassification = SystemMetadata;
    DataPerCompany = false;

    fields
    {
        field(1; "Table ID"; Integer)
        {
            Editable = false;
            Caption = 'Table ID';
        }
        field(2; "Session ID"; Integer)
        {
            Editable = false;
            Caption = 'Session ID';
        }
        field(3; "Session Unique ID"; Guid)
        {
            Editable = false;
            Caption = 'Session unique ID';
        }
        field(10; "Company Name"; Text[30])
        {
            Editable = false;
            Caption = 'Company name';
        }
    }

    keys
    {
        key(Key1; "Table ID", "Company Name")
        {
            Clustered = true;
        }

        key(SessionID; "Session ID")
        {
        }
    }

    fieldgroups
    {
        fieldgroup(DropDown; "Table ID", "Company Name")
        {
        }
        fieldgroup(Brick; "Table ID", "Company Name", "Session ID")
        {
        }
    }

    var
        SessionTerminatedMsg: Label 'Export to data lake session for table %1 terminated by user.', Comment = '%1 is the table name corresponding to the session';
        ExportDataInProgressErr: Label 'An export data process is already running. Please wait for it to finish.';
        InsertFailedErr: Label 'Could not start the export as there is already an active export running for the table %1. If this is not so, please stop all exports and try again.', Comment = '%1 = table caption';
        CouldNotStopSessionErr: Label 'Could not delete the export table session %1 for table on company %2.', Comment = '%1: session id, %2: company name';

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'id')]
    procedure Start(ADLSETableID: Integer)
    var
        ADLSEUtil: Codeunit "ADLSE Util";
    begin
        if Rec.Get(ADLSETableID, CompanyName()) then begin
            if IsSessionActive() then
                Error(InsertFailedErr, ADLSEUtil.GetTableCaption(ADLSETableID));

            // The entry was left by a session that ended without cleaning up after itself, or by a session
            // that is not listed as active. The export run is not failed: no new export starts while a run is
            // in process, so this session exports the table of the run.
            LogStaleSessionRemoved();
            Rec.Delete(false);
        end;

        Rec.Init();
        Rec."Table ID" := ADLSETableID;
        Rec."Session ID" := SessionId();
        Rec."Session Unique ID" := GetActiveSessionIDForSession(SessionId());
        Rec."Company Name" := CopyStr(CompanyName(), 1, 30);
        if not Rec.Insert(true) then
            Error(InsertFailedErr, ADLSEUtil.GetTableCaption(ADLSETableID));
    end;

    /// <summary>
    /// Logs that the entry of a session that is not listed as active is removed.
    /// </summary>
    internal procedure LogStaleSessionRemoved()
    var
        ADLSEExecution: Codeunit "ADLSE Execution";
        ADLSEUtil: Codeunit "ADLSE Util";
        CustomDimensions: Dictionary of [Text, Text];
    begin
        if Rec."Table ID" = GetExportReservationTableID() then
            CustomDimensions.Add('Entity', 'Export reservation')
        else
            CustomDimensions.Add('Entity', ADLSEUtil.GetTableCaption(Rec."Table ID"));
        CustomDimensions.Add('Table ID', Format(Rec."Table ID"));
        CustomDimensions.Add('Session ID', Format(Rec."Session ID"));
        CustomDimensions.Add('Session registered at', Format(Rec.SystemCreatedAt, 0, 9));
        ADLSEExecution.Log('ADLSE-058', 'Removed the entry of an export session that is not listed as active.', Verbosity::Warning, CustomDimensions);
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'rd')]
    procedure Stop(ADLSETableID: Integer; EmitTelemetry: Boolean; TableCaption: Text)
    var
        ADLSEExecution: Codeunit "ADLSE Execution";
        CustomDimensions: Dictionary of [Text, Text];
    begin
        if not Rec.Get(ADLSETableID, CompanyName()) then
            exit;
        CustomDimensions.Add('Entity', TableCaption);
        if not Rec.Delete(true) then
            ADLSEExecution.Log('ADLSE-036', StrSubstNo(CouldNotStopSessionErr, Rec."Session ID", CompanyName()), Verbosity::Error, CustomDimensions)
        else
            ADLSEExecution.Log('ADLSE-039', 'Session ended and was removed', Verbosity::Normal, CustomDimensions);
    end;

    procedure CheckForNoActiveSessions()
    begin
        if AreAnySessionsActive() then
            Error(ExportDataInProgressErr);
    end;

    /// <summary>
    /// Checks whether another session than the current one is exporting, or holds the export reservation, for the current company.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'r')]
    procedure AreAnySessionsActive() AnyActive: Boolean
    begin
        Rec.SetRange("Company Name", CopyStr(CompanyName(), 1, 30));
        if Rec.FindSet(false) then
            repeat
                if not IsOwnedByCurrentSession() then
                    if IsSessionActive() then begin
                        AnyActive := true;
                        exit;
                    end;
            until Rec.Next() = 0;
    end;

    /// <summary>
    /// Reserves the export of the current company for the current session, so that no other session can start
    /// an export or process the pending tables at the same time. Commit to make the reservation visible.
    /// </summary>
    /// <returns>False when another active session holds the reservation.</returns>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'rid')]
    procedure TryReserveExport(): Boolean
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
    begin
        ADLSECurrentSession.ReadIsolation := IsolationLevel::UpdLock;
        if ADLSECurrentSession.Get(GetExportReservationTableID(), CompanyName()) then begin
            if ADLSECurrentSession.IsOwnedByCurrentSession() then
                exit(true);
            if ADLSECurrentSession.IsSessionActive() then
                exit(false);
            // the session holding the reservation ended abnormally
            ADLSECurrentSession.LogStaleSessionRemoved();
            ADLSECurrentSession.Delete(false);
        end;

        ADLSECurrentSession.Init();
        ADLSECurrentSession."Table ID" := GetExportReservationTableID();
        ADLSECurrentSession."Session ID" := SessionId();
        ADLSECurrentSession."Session Unique ID" := GetActiveSessionIDForSession(SessionId());
        ADLSECurrentSession."Company Name" := CopyStr(CompanyName(), 1, MaxStrLen(ADLSECurrentSession."Company Name"));
        exit(ADLSECurrentSession.Insert(false));
    end;

    /// <summary>Releases the export reservation of the current company, when the current session holds it.</summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'rd')]
    procedure ReleaseExport()
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
    begin
        if not ADLSECurrentSession.Get(GetExportReservationTableID(), CompanyName()) then
            exit;
        if ADLSECurrentSession.IsOwnedByCurrentSession() then
            if ADLSECurrentSession.Delete(false) then;
    end;

    /// <summary>
    /// The export reservation is registered as a session for table ID 0, which is never exported.
    /// </summary>
    procedure GetExportReservationTableID(): Integer
    begin
        exit(0);
    end;

    /// <summary>Checks whether the current session still holds the export reservation of the current company.</summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'r')]
    internal procedure IsExportReservedByCurrentSession(): Boolean
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
    begin
        if not ADLSECurrentSession.Get(GetExportReservationTableID(), CompanyName()) then
            exit(false);
        exit(ADLSECurrentSession.IsOwnedByCurrentSession());
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'd')]
    procedure CleanupSessions()
    begin
        Rec.SetRange("Company Name", CopyStr(CompanyName(), 1, 30));
        Rec.DeleteAll(false);
    end;

    /// <summary>
    /// Checks whether the export of the table in the current company is registered by an active session other than the current one.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'r')]
    procedure IsTableOwnedByOtherActiveSession(ADLSETableID: Integer): Boolean
    begin
        if not Rec.Get(ADLSETableID, CompanyName()) then
            exit(false);
        if IsOwnedByCurrentSession() then
            exit(false);
        exit(IsSessionActive());
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'rd')]
    procedure CancelAll()
    var
        ADLSEUtil: Codeunit "ADLSE Util";
    begin
        if Rec.FindSet(false) then
            repeat
                // The export reservation is held by the session that starts the export, which can be a user's client session.
                if Rec."Table ID" <> GetExportReservationTableID() then
                    if IsSessionActive() then
                        Session.StopSession(Rec."Session ID", StrSubstNo(SessionTerminatedMsg, ADLSEUtil.GetTableCaption(Rec."Table ID")));
            until Rec.Next() = 0;

        Rec.DeleteAll(false);
    end;

    internal procedure IsOwnedByCurrentSession(): Boolean
    begin
        exit((Rec."Session ID" = SessionId()) and (Rec."Session Unique ID" = GetActiveSessionIDForSession(SessionId())));
    end;

    internal procedure IsSessionActive(): Boolean
    begin
        if IsListedAsActiveSession() then
            exit(true);
        // The active sessions do not reliably include a web service session that is still running, e.g. one handled by
        // another server instance. Starting an export takes seconds, so a recent export reservation is still in use.
        exit(IsRecentExportReservation());
    end;

    local procedure IsRecentExportReservation(): Boolean
    var
        ReservationValidityMs: Integer;
    begin
        if Rec."Table ID" <> GetExportReservationTableID() then
            exit(false);
        ReservationValidityMs := 15 * 60 * 1000;
        exit((CurrentDateTime() - Rec.SystemCreatedAt) < ReservationValidityMs);
    end;

    local procedure IsListedAsActiveSession(): Boolean
    var
        ActiveSession: Record "Active Session";
    begin
        if not IsNullGuid(Rec."Session Unique ID") then begin
            // The session may run on another server instance than the current one, so do not filter on the instance.
            ActiveSession.SetRange("Session ID", Rec."Session ID");
            ActiveSession.SetRange("Session Unique ID", Rec."Session Unique ID");
            exit(not ActiveSession.IsEmpty());
        end;

        ActiveSession.SetLoadFields("Session Unique ID");
        if ActiveSession.Get(ServiceInstanceId(), Rec."Session ID") then
            exit(ActiveSession."Session Unique ID" = Rec."Session Unique ID");
    end;

    procedure GetActiveSessionIDForSession(SessId: Integer): Guid
    var
        ActiveSession: Record "Active Session";
    begin
        ActiveSession.SetLoadFields("Session Unique ID");
        if ActiveSession.Get(ServiceInstanceId(), SessId) then;
        exit(ActiveSession."Session Unique ID");
    end;
}