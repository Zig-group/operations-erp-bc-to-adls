// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License. See LICENSE in the project root for license information.
namespace Zig.ADLSE;

/// <summary>
/// Runs the export of the enabled tables in isolation, so that the session starting the export
/// can always release the export reservation, also when the export fails.
/// </summary>
codeunit 11007455 "ADLSE Run Export"
{
    Access = Internal;
    TableNo = "ADLSE Table";

    trigger OnRun()
    var
        ADLSEExecution: Codeunit "ADLSE Execution";
    begin
        StartedCount := ADLSEExecution.RunExport(Rec);
    end;

    var
        StartedCount: Integer;

    procedure GetStartedCount(): Integer
    begin
        exit(StartedCount);
    end;
}
