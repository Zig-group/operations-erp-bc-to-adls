// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License. See LICENSE in the project root for license information.
namespace Zig.ADLSE;

/// <summary>
/// Queue of tables whose export session could not be started yet (e.g. because the
/// background session limit was reached). Replaces the former comma-separated value in
/// IsolatedStorage, which caused write conflicts (HTTP 409) when several sessions
/// updated the queue concurrently. Every row is claimed and deleted atomically.
/// </summary>
#pragma warning disable LC0015
table 11007174 "ADLSE Pending Table"
#pragma warning restore
{
    Access = Internal;
    Caption = 'ADLSE Pending Table';
    DataClassification = SystemMetadata;
    DataPerCompany = false;

    fields
    {
        field(1; "Company Name"; Text[30])
        {
            Editable = false;
            Caption = 'Company name';
        }
        field(2; "Table ID"; Integer)
        {
            Editable = false;
            Caption = 'Table ID';
        }
        field(3; "Queued At"; DateTime)
        {
            Editable = false;
            Caption = 'Queued at';
        }
        field(4; "Start Attempts"; Integer)
        {
            Editable = false;
            Caption = 'Start attempts';
        }
    }

    keys
    {
        key(Key1; "Company Name", "Table ID")
        {
            Clustered = true;
        }
        key(Key2; "Company Name", "Queued At")
        {
        }
    }

    fieldgroups
    {
        fieldgroup(DropDown; "Company Name", "Table ID")
        {
        }
        fieldgroup(Brick; "Company Name", "Table ID", "Queued At")
        {
        }
    }
}
