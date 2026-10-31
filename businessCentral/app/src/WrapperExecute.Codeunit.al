namespace Zig.ADLSE;

codeunit 11007178 "ADLSE Wrapper Execute"
{
    Access = Internal;
    TableNo = "ADLSE Table";

    trigger OnRun()
    var
        ADLSEExecute: Codeunit "ADLSE Execute";
        ADLSEExecution: Codeunit "ADLSE Execution";
        CustomDimensions: Dictionary of [Text, Text];
        ErrorText: Text;
    begin
        if not ADLSEExecute.Run(Rec) then begin
            ErrorText := GetLastErrorText();
            CustomDimensions.Add('Entity', Format(Rec."Table ID"));
            CustomDimensions.Add('SessionId', Format(SessionId()));
            CustomDimensions.Add('AL Call Stack', GetLastErrorCallStack());
            CustomDimensions.Add('Last Error Code', GetLastErrorCode());
            CustomDimensions.Add('Last Error Text', ErrorText);
            ADLSEExecution.Log('ADLSE-050', 'Session is failes to start', Verbosity::Normal, CustomDimensions);
            HandleExportFailure(Rec, ErrorText);
        end;
    end;

    /// <summary>
    /// Releases the table and fails its run when the export session errors out, so that the table
    /// is not left in process, and keeps the remaining tables of the export going.
    /// </summary>
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Current Session", 'rd')]
    [InherentPermissions(PermissionObjectType::TableData, Database::"ADLSE Run", 'rim')]
    local procedure HandleExportFailure(var ADLSETable: Record "ADLSE Table"; ErrorText: Text)
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
        ADLSERun: Record "ADLSE Run";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
        ADLSEExecute: Codeunit "ADLSE Execute";
        ADLSEExecution: Codeunit "ADLSE Execution";
        ADLSEUtil: Codeunit "ADLSE Util";
        CustomDimensions: Dictionary of [Text, Text];
        TableCaption: Text;
        RunFailed: Boolean;
    begin
        TableCaption := ADLSEUtil.GetTableCaption(ADLSETable."Table ID");
        CustomDimensions.Add('Entity', TableCaption);

        // Another active session is exporting this table, e.g. after a duplicate start. Leave its state alone.
        if ADLSECurrentSession.IsTableOwnedByOtherActiveSession(ADLSETable."Table ID") then begin
            ADLSEExecution.Log('ADLSE-056', 'Export session not started as the table is already being exported by another session.', Verbosity::Warning, CustomDimensions);
            exit;
        end;

        ADLSECurrentSession.Stop(ADLSETable."Table ID", false, TableCaption);
        RunFailed := ADLSERun.RegisterFailed(ADLSETable."Table ID", ErrorText, false);
        Commit();

        // The run is not in process when the error occurred after the export had already been finalized.
        if not RunFailed then
            exit;

        ADLSESessionManager.StartExportFromPendingTables();
        ADLSEExecute.NotifyExportFinishedIfDone(ADLSETable, TableCaption);
    end;
}