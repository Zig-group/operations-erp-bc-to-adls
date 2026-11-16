// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License. See LICENSE in the project root for license information.
namespace Zig.ADLSE;

/// <summary>
/// Starts the export of a single table. Run through Codeunit.Run so that an error for
/// one table (e.g. a lock timeout while checking for changes) does not abort the export
/// of all other tables.
/// </summary>
codeunit 11007454 "ADLSE Start Table Export"
{
    Access = Internal;
    TableNo = "ADLSE Table";

    trigger OnRun()
    var
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        if PendingStart then
            Started := ADLSESessionManager.StartPendingExport(Rec."Table ID", EmitTelemetry, StartAttempts)
        else
            Started := ADLSESessionManager.StartExport(Rec."Table ID", EmitTelemetry);
    end;

    var
        EmitTelemetry: Boolean;
        Started: Boolean;
        PendingStart: Boolean;
        StartAttempts: Integer;

    procedure SetEmitTelemetry(NewEmitTelemetry: Boolean)
    begin
        EmitTelemetry := NewEmitTelemetry;
    end;

    /// <summary>Starts the table as one taken from the pending tables queue.</summary>
    procedure SetPendingStart(NewStartAttempts: Integer)
    begin
        PendingStart := true;
        StartAttempts := NewStartAttempts;
    end;

    procedure WasStarted(): Boolean
    begin
        exit(Started);
    end;
}
