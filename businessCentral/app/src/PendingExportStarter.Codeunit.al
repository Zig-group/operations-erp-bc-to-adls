// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License. See LICENSE in the project root for license information.
namespace Zig.ADLSE;

/// <summary>
/// Scheduled task that starts the export sessions for tables left in the pending queue
/// when no running export session is left to pick them up.
/// </summary>
codeunit 11007453 "ADLSE Pending Export Starter"
{
    Access = Internal;

    trigger OnRun()
    var
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        ADLSESessionManager.ProcessPendingTablesFromTask();
    end;
}
