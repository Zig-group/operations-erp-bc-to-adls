// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License. See LICENSE in the project root for license information.
namespace Zig.ADLSE;

#pragma warning disable LC0004, LC0015
table 11007166 "ADLSE Run"
#pragma warning restore
{
    Access = Internal;
    Caption = 'ADLSE Run';
    DataClassification = CustomerContent;
    DataPerCompany = false;

    fields
    {
        field(1; ID; Integer)
        {
            AllowInCustomizations = AsReadOnly;
            Editable = false;
            Caption = 'ID';
            AutoIncrement = true;
        }
        field(2; "Table ID"; Integer)
        {
            AllowInCustomizations = AsReadOnly;
            Editable = false;
            Caption = 'Table ID';
        }
        field(3; "Company Name"; Text[30])
        {
            AllowInCustomizations = AsReadOnly;
            Editable = false;
            Caption = 'Company name';
        }
        field(4; State; Enum "ADLSE Run State")
        {
            Editable = false;
            Caption = 'State';
            ToolTip = 'Specifies the state of the execution of export.';
        }
        field(5; "Error"; Text[2048])
        {
            Editable = false;
            Caption = 'Error';
            ToolTip = 'Specifies the error if the execution had any.';
        }
        field(6; Started; DateTime)
        {
            Editable = false;
            Caption = 'Started';
            ToolTip = 'Specifies when the export was started.';
        }
        field(7; Ended; DateTime)
        {
            Editable = false;
            Caption = 'Ended';
            ToolTip = 'Specifies when the export was started.';
        }
    }

    keys
    {
        key(Key1; ID)
        {
            Clustered = true;
        }
        key(Key2; "Table ID", "Company Name")
        {
        }
        key(Key3; Started)
        { // sorting key
        }
    }

    fieldgroups
    {
        fieldgroup(DropDown; ID, "Table ID", "Company Name")
        {
        }
        fieldgroup(Brick; ID, "Table ID", "Company Name", State, Started)
        {
        }
    }

    var
        ExportRunNotFoundErr: Label 'No export process running for table.';
        ExportStoppedDueToCancelledSessionTxt: Label 'Export stopped as session was cancelled. Please check state of the export on the data lake before enabling this.';
        ExportExceededSessionTimeoutErr: Label 'The export did not finish within the timeout of the export session, so it was stopped. The table is exported again with the next export.';
        CouldNotUpdateExportRunStatusErr: Label 'Could not update the status of the export run for table to %1.', Comment = '%1: New status';

    procedure GetLastRunDetails(TableID: Integer; var Status: Enum "ADLSE Run State"; var StartedTime: DateTime; var ErrorIfAny: Text[2048])
    begin
        if FindLastRun(TableID) then begin
            Status := Rec.State;
            StartedTime := Rec.Started;
            ErrorIfAny := Rec.Error;
            exit;
        end;
        Status := "ADLSE Run State"::None;
        StartedTime := 0DT;
        ErrorIfAny := '';
    end;

    procedure Duration(): Duration
    begin
        if (Started = 0DT) or (Ended = 0DT) then
            exit(0);
        exit(Round(Ended - Started, 100));
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'rim')]
    procedure RegisterStarted(TableID: Integer)
    begin
        // Reuse the run registered when the export was queued or started, so that each export has a single run.
        if FindLastRun(TableID) then
            if Rec.State = "ADLSE Run State"::InProcess then begin
                Rec.Started := CurrentDateTime();
                Rec.Ended := 0DT;
                Rec.Error := '';
                Rec.Modify(true);
                exit;
            end;

        InitNewRun(TableID);
        Rec.State := "ADLSE Run State"::InProcess;
        Rec.Insert(true);
    end;

    /// <summary>
    /// Registers an export run as in process for a table whose export session is about to be started
    /// or has been queued. When the last run of the table is already in process, its start time is
    /// refreshed, so that a session that is starting for it is recognized as such.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'rim')]
    procedure RegisterQueued(TableID: Integer)
    begin
        if FindLastRun(TableID) then
            if Rec.State = "ADLSE Run State"::InProcess then begin
                Rec.Started := CurrentDateTime();
                Rec.Modify(true);
                exit;
            end;

        InitNewRun(TableID);
        Rec.State := "ADLSE Run State"::InProcess;
        Rec.Insert(true);
    end;

    /// <summary>
    /// Marks the in-process run of a table as failed. When the last run is not in process, a failed run
    /// is inserted only if InsertIfNotInProcess is set, so the next export is forced for the table.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'rim')]
    procedure RegisterFailed(TableID: Integer; ErrorText: Text; InsertIfNotInProcess: Boolean) Registered: Boolean
    var
        ADLSEExternalEvents: Codeunit "ADLSE External Events";
        InProcess: Boolean;
    begin
        if FindLastRun(TableID) then
            InProcess := Rec.State = "ADLSE Run State"::InProcess;

        if not InProcess then begin
            if not InsertIfNotInProcess then
                exit(false);
            InitNewRun(TableID);
            Rec.Insert(true);
        end;

        Rec.State := "ADLSE Run State"::Failed;
        Rec.Error := CopyStr(ErrorText, 1, MaxStrLen(Rec.Error));
        Rec.Ended := CurrentDateTime();
        Rec.Modify(true);
        ADLSEExternalEvents.OnTableExportRunEnded(Rec.ID, Rec.Started, Rec.Ended, Rec."Table ID", Rec.State);
        exit(true);
    end;

    /// <summary>
    /// Fails the in-process runs of the current company that started longer ago than the timeout of an export
    /// session. The platform ends an export session at its timeout, so such a run can never be completed anymore,
    /// e.g. because its session was ended by a restart. The queue entry and session entry of the table are removed.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'rm')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Pending Table", 'rd')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'rd')]
    procedure CancelExpiredRuns()
    var
        ADLSERun: Record "ADLSE Run";
        ADLSEPendingTable: Record "ADLSE Pending Table";
        ADLSECurrentSession: Record "ADLSE Current Session";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
        ADLSEExecution: Codeunit "ADLSE Execution";
        ADLSEUtil: Codeunit "ADLSE Util";
        CustomDimensions: Dictionary of [Text, Text];
    begin
        Rec.Reset();
        Rec.SetRange("Company Name", CompanyName());
        Rec.SetRange(State, "ADLSE Run State"::InProcess);
        Rec.SetFilter(Started, '<%1', CurrentDateTime() - ADLSESessionManager.GetExportSessionTimeout() - GetExpiryMargin());
        if Rec.FindSet(false) then
            repeat
                ADLSERun := Rec;
                ADLSERun.Ended := CurrentDateTime();
                ADLSERun.Error := ExportExceededSessionTimeoutErr;
                ADLSERun.State := "ADLSE Run State"::Failed;
                ADLSERun.Modify(true);

                if ADLSEPendingTable.Get(CopyStr(CompanyName(), 1, MaxStrLen(ADLSEPendingTable."Company Name")), ADLSERun."Table ID") then
                    ADLSEPendingTable.Delete(false);
                if ADLSECurrentSession.Get(ADLSERun."Table ID", CompanyName()) then
                    ADLSECurrentSession.Delete(false);

                Clear(CustomDimensions);
                CustomDimensions.Add('Entity', ADLSEUtil.GetTableCaption(ADLSERun."Table ID"));
                CustomDimensions.Add('Table ID', Format(ADLSERun."Table ID"));
                CustomDimensions.Add('Run started', Format(ADLSERun.Started, 0, 9));
                ADLSEExecution.Log('ADLSE-061', 'Failed an export run that did not finish within the session timeout.', Verbosity::Warning, CustomDimensions);
            until Rec.Next() = 0;
    end;

    local procedure GetExpiryMargin(): Duration
    begin
        // The run is registered just before its export session is started.
        exit(60 * 60 * 1000); // 1 hour
    end;

    /// <summary>
    /// Checks whether a run of the current company is in process. This also covers tables that are
    /// queued or whose export session is starting, as these are registered as in process up front.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'r')]
    procedure AnyRunInProcess(): Boolean
    var
        ADLSERun: Record "ADLSE Run";
    begin
        ADLSERun.SetRange("Company Name", CompanyName());
        ADLSERun.SetRange(State, "ADLSE Run State"::InProcess);
        exit(not ADLSERun.IsEmpty());
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'm')]
    procedure RegisterEnded(TableID: Integer; EmitTelemetry: Boolean; TableCaption: Text)
    var
        ADLSEExecution: Codeunit "ADLSE Execution";
        ADLSEExternalEvents: Codeunit "ADLSE External Events";
        CustomDimensions: Dictionary of [Text, Text];
        LastErrorMessage: Text;
    begin
        CustomDimensions.Add('Entity', TableCaption);
        if not FindLastRunInProcess(TableID, CustomDimensions) then
            exit;

        LastErrorMessage := GetLastErrorText();
        if LastErrorMessage <> '' then
            if Rec.Error = '' then // do not overwrite a previous error message
                FillErrorDetails(LastErrorMessage, EmitTelemetry, CustomDimensions);

        if Rec.Error = '' then
            Rec.State := "ADLSE Run State"::Success
        else
            Rec.State := "ADLSE Run State"::Failed;

        Rec.Ended := CurrentDateTime();
        ADLSEExternalEvents.OnTableExportRunEnded(Rec.ID, Rec.Started, Rec.Ended, Rec."Table ID", Rec.State);
        if not Rec.Modify(true) then
            ADLSEExecution.Log('ADLSE-035', StrSubstNo(CouldNotUpdateExportRunStatusErr, Rec.State), Verbosity::Error, CustomDimensions)
        else
            ADLSEExecution.Log('ADLSE-038', 'The export run was registered as ended.', Verbosity::Normal, CustomDimensions);
    end;

    procedure RegisterErrorInProcess(TableID: Integer; EmitTelemetry: Boolean; TableCaption: Text)
    var
        CustomDimensions: Dictionary of [Text, Text];
        LastErrorMessage: Text;
    begin
        CustomDimensions.Add('Entity', TableCaption);
        if not FindLastRunInProcess(TableID, CustomDimensions) then
            exit;

        LastErrorMessage := GetLastErrorText();
        if LastErrorMessage <> '' then
            FillErrorDetails(LastErrorMessage, EmitTelemetry, CustomDimensions);
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'm')]
    local procedure FillErrorDetails(LastErrorMessage: Text; EmitTelemetry: Boolean; CustomDimensions: Dictionary of [Text, Text])
    var
        ADLSEExecution: Codeunit "ADLSE Execution";
        LastErrorStack: Text;
    begin
        LastErrorStack := GetLastErrorCallStack();
        Rec.Error := CopyStr(LastErrorMessage + LastErrorStack, 1, 2048); // 2048 is the max size of the field 
        Rec.Modify(true);

        if EmitTelemetry then begin
            CustomDimensions.Add('Error text', LastErrorMessage);
            CustomDimensions.Add('Error stack', LastErrorStack);
            ADLSEExecution.Log('ADLSE-008', 'Error occured during execution', Verbosity::Error, CustomDimensions);
        end;
        ClearLastError();
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'm')]
    procedure CancelAllRuns()
    begin
        Rec.SetRange(State, "ADLSE Run State"::InProcess);
        Rec.ModifyAll(Ended, CurrentDateTime, true);
        Rec.ModifyAll(State, "ADLSE Run State"::Failed, true);
        Rec.ModifyAll(Error, ExportStoppedDueToCancelledSessionTxt, true);
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'm')]
    procedure CancelRun(TableID: Integer)
    begin
        if not FindLastRun(TableID) then
            exit;
        Rec.Validate(Ended, CurrentDateTime());
        Rec.Validate(State, "ADLSE Run State"::Failed);
        Rec.Validate(Error, ExportStoppedDueToCancelledSessionTxt);
        Rec.Modify(true);
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'r')]
    procedure OldRunsExist(): Boolean
    begin
        CommmonFilterOnOldRuns();
        exit(not Rec.IsEmpty());
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'd')]
    procedure DeleteOldRuns()
    begin
        CommmonFilterOnOldRuns();
        Rec.DeleteAll(false);
    end;

    procedure DeleteOldRuns(TableID: Integer)
    begin
        Rec.SetRange("Table ID", TableID);
        DeleteOldRuns();
    end;

    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE run", 'r')]
    local procedure FindLastRun(TableID: Integer) Found: Boolean
    begin
        Rec.SetCurrentKey(ID);
        Rec.Ascending(false); // order results in a way that the last one shows up first
        Rec.SetRange("Table ID", TableID);
        Rec.SetRange("Company Name", CompanyName());
        Found := Rec.FindFirst();
    end;

    local procedure FindLastRunInProcess(TableID: Integer; CustomDimensions: Dictionary of [Text, Text]): Boolean
    var
        ADLSEExecution: Codeunit "ADLSE Execution";
    begin
        if not FindLastRun(TableID) then begin
            ADLSEExecution.Log('ADLSE-034', ExportRunNotFoundErr, Verbosity::Error, CustomDimensions);
            exit(false);
        end;
        exit(Rec.State = "ADLSE Run State"::InProcess);
    end;

    local procedure InitNewRun(TableID: Integer)
    begin
        Rec.Reset();
        Rec.Init();
        Rec.ID := 0; // Init keeps the primary key of the run loaded before, so let AutoIncrement assign a new one
        Rec."Table ID" := TableID;
        Rec."Company Name" := CopyStr(CompanyName(), 1, MaxStrLen(Rec."Company Name"));
        Rec.Started := CurrentDateTime();
    end;

    local procedure CommmonFilterOnOldRuns()
    begin
        Rec.SetFilter(State, '<>%1', "ADLSE Run State"::InProcess);
        Rec.SetRange("Company Name", CompanyName());
    end;
}