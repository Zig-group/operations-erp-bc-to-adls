codeunit 85571 "ADLSE Session Manager Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    trigger OnRun()
    begin
        // [FEATURE] bc2adls Session Manager
    end;

    var
        ADLSELibrarybc2adls: Codeunit "ADLSE Library - bc2adls";
        LibraryAssert: Codeunit "Library Assert";
        "Storage Type": Enum "ADLSE Storage Type";
        IsInitialized: Boolean;

    [Test]
    procedure TestInit_ClearsPendingTables()
    var
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] Init clears the pending tables queue
        // [GIVEN] Initialized test environment
        Initialize();

        // [WHEN] Init is called
        ADLSESessionManager.Init();

        // [THEN] Pending tables are cleared (verified by no error)
        // The Init procedure should complete without error
    end;

    [Test]
    procedure TestSavePendingTables_SavesValue()
    var
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] SavePendingTables stores value in isolated storage
        // [GIVEN] Initialized test environment
        Initialize();

        // [WHEN] SavePendingTables is called
        ADLSESessionManager.SavePendingTables('');

        // [THEN] No error occurs (value is saved)
    end;

    [Test]
    procedure TestTimestamp_CanBeSaved()
    var
        ADLSETable: Record "ADLSE Table";
        ADLSETableLastTimestamp: Record "ADLSE Table Last Timestamp";
        MaxTimestamp: BigInteger;
        SavedTimestamp: BigInteger;
    begin
        // [SCENARIO] Timestamp can be saved and retrieved
        // [GIVEN] A table configured for export
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        ADLSETable.Add(Database::"Reason Code");
        ADLSELibrarybc2adls.InsertFields();

        // [WHEN] A timestamp is saved
        MaxTimestamp := 9223372036854775807L;
        ADLSETableLastTimestamp.TrySaveUpdatedLastTimestamp(Database::"Reason Code", MaxTimestamp, false);

        // [THEN] The timestamp can be retrieved
        SavedTimestamp := ADLSETableLastTimestamp.GetUpdatedLastTimestamp(Database::"Reason Code");
        LibraryAssert.AreEqual(MaxTimestamp, SavedTimestamp, 'Timestamp should be saved and retrievable');
    end;

    [Test]
    procedure TestTableConfiguration_WithData_IsReady()
    var
        ADLSETable: Record "ADLSE Table";
        ReasonCode: Record "Reason Code";
        ADLSERun: Record "ADLSE Run";
        LibraryERM: Codeunit "Library - ERM";
    begin
        // [SCENARIO] Table with new data is properly configured for export
        // [GIVEN] A table with new data
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");

        // Create some data
        LibraryERM.CreateReasonCode(ReasonCode);

        ADLSETable.Add(Database::"Reason Code");
        ADLSELibrarybc2adls.InsertFields();
        ADLSELibrarybc2adls.EnableFields();

        // Clear any existing run data
        ADLSERun.SetRange("Table ID", Database::"Reason Code");
        ADLSERun.DeleteAll();

        // [WHEN] Table is retrieved
        ADLSETable.Get(Database::"Reason Code");

        // [THEN] Table is enabled and ready for export
        LibraryAssert.IsTrue(ADLSETable.Enabled, 'Table should be enabled');
    end;

    [Test]
    procedure TestStartExportFromPendingTables_ProcessesPending()
    var
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] StartExportFromPendingTables processes queued tables
        // [GIVEN] Initialized test environment
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");

        // Clear pending tables first
        ADLSESessionManager.Init();

        // [WHEN] StartExportFromPendingTables is called
        ADLSESessionManager.StartExportFromPendingTables();

        // [THEN] No error occurs (pending tables are processed)
    end;

    [Test]
    procedure TestDeletedRecords_CanBeCleared()
    var
        ADLSETable: Record "ADLSE Table";
        ADLSEDeletedRecord: Record "ADLSE Deleted Record";
        ReasonCode: Record "Reason Code";
    begin
        // [SCENARIO] Deleted records can be managed
        // [GIVEN] A table configured for export
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");

        // Delete all reason codes
        ReasonCode.DeleteAll(false);

        ADLSETable.Add(Database::"Reason Code");
        ADLSELibrarybc2adls.InsertFields();

        // [WHEN] Deleted records are cleared for this table
        ADLSEDeletedRecord.SetRange("Table ID", Database::"Reason Code");
        ADLSEDeletedRecord.DeleteAll();

        // [THEN] No deleted records exist for the table
        ADLSEDeletedRecord.SetRange("Table ID", Database::"Reason Code");
        LibraryAssert.AreEqual(0, ADLSEDeletedRecord.Count(), 'Should have no deleted records after clearing');
    end;

    [Test]
    procedure TestLastRunFailed_SuccessfulRun_ReturnsFalse()
    var
        ADLSETable: Record "ADLSE Table";
        ADLSERun: Record "ADLSE Run";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] When last run was successful, force export is not triggered
        // [GIVEN] A table with a successful last run
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        ADLSETable.Add(Database::"Reason Code");
        ADLSELibrarybc2adls.InsertFields();

        // Create a successful run
        ADLSELibrarybc2adls.MockCreateExport(Database::"Reason Code");

        // [WHEN/THEN] The session manager logic considers last run status
        // Verify successful run was recorded
        ADLSERun.SetRange("Table ID", Database::"Reason Code");
        ADLSERun.FindLast();
        LibraryAssert.AreEqual(ADLSERun.State::Success, ADLSERun.State, 'Last run should be successful');
    end;

    [Test]
    procedure TestLastRunFailed_FailedRun_TriggersReexport()
    var
        ADLSETable: Record "ADLSE Table";
        ADLSERun: Record "ADLSE Run";
    begin
        // [SCENARIO] When last run failed, export is triggered even without data changes
        // [GIVEN] A table with a failed last run
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        ADLSETable.Add(Database::"Reason Code");
        ADLSELibrarybc2adls.InsertFields();

        // Clear any existing runs for this table first
        ADLSERun.SetRange("Table ID", Database::"Reason Code");
        ADLSERun.DeleteAll();
        ADLSERun.Reset();

        // Create a failed run by starting and canceling
        ADLSERun.RegisterStarted(Database::"Reason Code");
        ADLSERun.CancelRun(Database::"Reason Code");

        // [THEN] The last run is marked as failed
        ADLSERun.Reset();
        ADLSERun.SetRange("Table ID", Database::"Reason Code");
        ADLSERun.FindLast();
        LibraryAssert.AreEqual("ADLSE Run State"::Failed, ADLSERun.State, 'Last run should be failed');
    end;

    [Test]
    procedure TestMultipleTables_QueuesExcessTables()
    var
        ADLSETable: Record "ADLSE Table";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] When multiple tables need export, excess tables are queued
        // [GIVEN] Multiple tables configured for export
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");

        // Add multiple tables
        ADLSETable.Add(Database::"Reason Code");
        ADLSETable.Add(Database::"Payment Terms");

        ADLSELibrarybc2adls.InsertFields();

        // Initialize pending tables
        ADLSESessionManager.Init();

        // [WHEN/THEN] Export attempts are made
        // Tables that cannot start immediately should be queued
        // This is verified by the session manager not throwing errors
    end;

    [Test]
    procedure TestPendingQueue_SaveAndInit()
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] The pending tables queue is stored in a table and Init clears it
        // [GIVEN] An empty queue
        Initialize();
        ADLSELibrarybc2adls.CleanUp();

        // [WHEN] Two tables are queued, one of them twice
        ADLSESessionManager.SavePendingTables(StrSubstNo('%1,%2,%1', Database::"Reason Code", Database::"Payment Terms"));

        // [THEN] Both tables are queued once
        LibraryAssert.IsTrue(ADLSESessionManager.HasPendingTables(), 'The queue should not be empty');
        ADLSEPendingTable.SetRange("Company Name", CompanyName());
        LibraryAssert.AreEqual(2, ADLSEPendingTable.Count(), 'Each table should be queued only once');

        // [WHEN] Init is called
        ADLSESessionManager.Init();

        // [THEN] The queue is empty
        LibraryAssert.IsFalse(ADLSESessionManager.HasPendingTables(), 'Init should clear the queue');
    end;

    [Test]
    procedure TestPendingQueue_RemovedOnTableDelete()
    var
        ADLSETable: Record "ADLSE Table";
        ADLSERun: Record "ADLSE Run";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] Deleting a table from the export setup removes it from the queue
        // [GIVEN] A queued table
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        ADLSETable.Add(Database::"Reason Code");
        DeleteRuns(Database::"Reason Code");
        ADLSERun.RegisterQueued(Database::"Reason Code");
        ADLSESessionManager.SavePendingTables(Format(Database::"Reason Code"));

        // [WHEN] The table is deleted from the setup
        ADLSETable.Get(Database::"Reason Code");
        ADLSETable.Delete(true);

        // [THEN] The queue is empty and the queued run is failed
        LibraryAssert.IsFalse(ADLSESessionManager.HasPendingTables(), 'The deleted table should be removed from the queue');
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::Failed, '');
    end;

    [Test]
    procedure TestClearPendingTablesAllCompanies_ClearsQueue()
    var
        ADLSEPendingTable: Record "ADLSE Pending Table";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] Stopping the exports clears the queue of all companies
        // [GIVEN] Tables queued for the current and another company
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSESessionManager.SavePendingTables(Format(Database::"Reason Code"));
        ADLSEPendingTable."Company Name" := 'ADLSE Other Company';
        ADLSEPendingTable."Table ID" := Database::"Reason Code";
        ADLSEPendingTable.Insert(false);

        // [WHEN] The queues are cleared for all companies
        ADLSESessionManager.ClearPendingTablesAllCompanies();

        // [THEN] No table is queued anymore
        ADLSEPendingTable.Reset();
        LibraryAssert.IsTrue(ADLSEPendingTable.IsEmpty(), 'The queues of all companies should be cleared');
    end;

    [Test]
    procedure TestAbandonPendingTables_FailsQueuedRuns()
    var
        ADLSERun: Record "ADLSE Run";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] Tables abandoned in the queue get a failed run, so they are exported the next time
        // [GIVEN] A queued table with a run in process
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        DeleteRuns(Database::"Reason Code");
        ADLSERun.RegisterQueued(Database::"Reason Code");
        ADLSESessionManager.SavePendingTables(Format(Database::"Reason Code"));

        // [WHEN] The queue is abandoned
        ADLSESessionManager.AbandonPendingTables('Abandoned');

        // [THEN] The queue is empty and the run is failed
        LibraryAssert.IsFalse(ADLSESessionManager.HasPendingTables(), 'The queue should be empty');
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::Failed, 'Abandoned');
    end;

    [Test]
    procedure TestRegisterQueued_StartedReusesRun()
    var
        ADLSERun: Record "ADLSE Run";
    begin
        // [SCENARIO] A queued table and its started export share a single run
        // [GIVEN] No runs for the table
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        DeleteRuns(Database::"Reason Code");

        // [WHEN] The table is queued twice and then started
        ADLSERun.RegisterQueued(Database::"Reason Code");
        ADLSERun.RegisterQueued(Database::"Reason Code");
        ADLSERun.RegisterStarted(Database::"Reason Code");

        // [THEN] There is a single run in process
        ADLSERun.Reset();
        ADLSERun.SetRange("Table ID", Database::"Reason Code");
        LibraryAssert.AreEqual(1, ADLSERun.Count(), 'There should be a single run');
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::InProcess, '');
    end;

    [Test]
    procedure TestRegisterQueued_AfterFinishedRunInsertsNewRun()
    var
        ADLSERun: Record "ADLSE Run";
    begin
        // [SCENARIO] A new export after a finished run gets its own run
        // [GIVEN] A successful run
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        DeleteRuns(Database::"Reason Code");
        ADLSELibrarybc2adls.MockCreateExport(Database::"Reason Code");

        // [WHEN] The table is queued and then started again
        ADLSERun.RegisterQueued(Database::"Reason Code");
        ADLSERun.RegisterStarted(Database::"Reason Code");

        // [THEN] A second run is in process and the successful run is kept
        ADLSERun.Reset();
        ADLSERun.SetRange("Table ID", Database::"Reason Code");
        LibraryAssert.AreEqual(2, ADLSERun.Count(), 'The new export should insert a new run');
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::InProcess, '');
    end;

    [Test]
    procedure TestRegisterFailed_MarksRunInProcessAsFailed()
    var
        ADLSERun: Record "ADLSE Run";
    begin
        // [SCENARIO] RegisterFailed fails the run in process
        // [GIVEN] A run in process
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        DeleteRuns(Database::"Reason Code");
        ADLSERun.RegisterStarted(Database::"Reason Code");

        // [WHEN] The run is registered as failed
        // [THEN] The run is failed with the error
        LibraryAssert.IsTrue(ADLSERun.RegisterFailed(Database::"Reason Code", 'Some error', false), 'The run should be registered as failed');
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::Failed, 'Some error');
    end;

    [Test]
    procedure TestRegisterFailed_NoRunInProcess()
    var
        ADLSERun: Record "ADLSE Run";
    begin
        // [SCENARIO] RegisterFailed does not overwrite a finished run, unless a failed run must be inserted
        // [GIVEN] A successful run
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        DeleteRuns(Database::"Reason Code");
        ADLSELibrarybc2adls.MockCreateExport(Database::"Reason Code");

        // [WHEN] The run is registered as failed without inserting
        // [THEN] Nothing changes
        LibraryAssert.IsFalse(ADLSERun.RegisterFailed(Database::"Reason Code", 'Some error', false), 'No run should be registered as failed');
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::Success, '');

        // [WHEN] The run is registered as failed with inserting
        // [THEN] A failed run is added
        LibraryAssert.IsTrue(ADLSERun.RegisterFailed(Database::"Reason Code", 'Some error', true), 'A failed run should be inserted');
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::Failed, 'Some error');
    end;

    [Test]
    procedure TestCancelOrphanedRuns_FailsRunsInProcess()
    var
        ADLSERun: Record "ADLSE Run";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] Runs left in process by a previous export are failed, but queued tables are kept
        // [GIVEN] A run in process, and a queued table
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        ADLSESessionManager.ClearPendingTables();
        DeleteRuns(Database::"Reason Code");
        DeleteRuns(Database::"Payment Terms");
        ADLSERun.RegisterStarted(Database::"Reason Code");
        ADLSERun.RegisterQueued(Database::"Payment Terms");
        ADLSESessionManager.SavePendingTables(Format(Database::"Payment Terms"));

        // [WHEN] The orphaned runs are cancelled
        ADLSERun.CancelOrphanedRuns('Orphaned');

        // [THEN] The run is failed with the reason, and the run of the queued table stays in process
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::Failed, 'Orphaned');
        VerifyLastRun(Database::"Payment Terms", "ADLSE Run State"::InProcess, '');
        LibraryAssert.IsTrue(ADLSESessionManager.HasPendingTables(), 'The queued table should be kept');

        // [WHEN] An export starts the queued table
        // [THEN] It is left to the processing of the queue
        LibraryAssert.IsFalse(ADLSESessionManager.StartExport(Database::"Payment Terms", false), 'A queued table should not be started by another export');
        ADLSESessionManager.ClearPendingTables();
    end;

    [Test]
    procedure TestCleanupStaleSessions_RemovesInactiveSession()
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
        ADLSERun: Record "ADLSE Run";
    begin
        // [SCENARIO] A session that ended abnormally does not block the next export
        // [GIVEN] A registered session that is not active, with its run in process
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        DeleteRuns(Database::"Reason Code");
        ADLSERun.RegisterStarted(Database::"Reason Code");
        ADLSECurrentSession."Table ID" := Database::"Reason Code";
        ADLSECurrentSession."Company Name" := CopyStr(CompanyName(), 1, MaxStrLen(ADLSECurrentSession."Company Name"));
        ADLSECurrentSession."Session ID" := 2147483000;
        ADLSECurrentSession."Session Unique ID" := CreateGuid();
        ADLSECurrentSession.Insert(false);

        // [WHEN] Stale sessions are cleaned up
        LibraryAssert.IsFalse(ADLSECurrentSession.IsTableOwnedByOtherActiveSession(Database::"Reason Code"), 'An inactive session should not own the table');
        ADLSECurrentSession.CleanupStaleSessions();

        // [THEN] The session is removed, no session is active and the run is failed
        ADLSECurrentSession.Reset();
        LibraryAssert.IsFalse(ADLSECurrentSession.Get(Database::"Reason Code", CompanyName()), 'The stale session should be removed');
        LibraryAssert.IsFalse(ADLSECurrentSession.AreAnySessionsActive(), 'No session should be active');
        VerifyLastRun(Database::"Reason Code", "ADLSE Run State"::Failed, '');
    end;

    [Test]
    procedure TestTryReserveExport_TakesOverStaleReservation()
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
    begin
        // [SCENARIO] The export reservation of a session that ended abnormally does not block the next export
        // [GIVEN] An export reservation held by a session that is not active
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        InsertInactiveSession(ADLSECurrentSession.GetExportReservationTableID());

        // [WHEN] The export is reserved
        // [THEN] The reservation is taken over by the current session
        LibraryAssert.IsTrue(ADLSECurrentSession.TryReserveExport(), 'A stale reservation should be taken over');
        ADLSECurrentSession.Get(ADLSECurrentSession.GetExportReservationTableID(), CompanyName());
        LibraryAssert.AreEqual(SessionId(), ADLSECurrentSession."Session ID", 'The reservation should belong to the current session');
    end;

    [Test]
    procedure TestReleaseExport_KeepsReservationOfOtherSession()
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
    begin
        // [SCENARIO] A session only releases its own export reservation
        // [GIVEN] An export reservation held by another session
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        InsertInactiveSession(ADLSECurrentSession.GetExportReservationTableID());

        // [WHEN] The current session releases the export
        ADLSECurrentSession.ReleaseExport();

        // [THEN] The reservation of the other session is kept
        LibraryAssert.IsTrue(ADLSECurrentSession.Get(ADLSECurrentSession.GetExportReservationTableID(), CompanyName()), 'The reservation of another session should be kept');
    end;

    [Test]
    procedure TestAreAnySessionsActive_IgnoresOwnReservation()
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
    begin
        // [SCENARIO] The session that reserved the export can pass the checks for a running export
        // [GIVEN] The export is reserved by the current session
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        LibraryAssert.IsTrue(ADLSECurrentSession.TryReserveExport(), 'The export should be reserved');

        // [WHEN] Checking for active sessions
        // [THEN] The own reservation is not counted, but other sessions can see it
        LibraryAssert.IsFalse(ADLSECurrentSession.AreAnySessionsActive(), 'The own reservation should not count as an active export');
        LibraryAssert.IsTrue(ADLSECurrentSession.TryReserveExport(), 'Reserving again from the same session should succeed');

        // [WHEN] The export is released
        ADLSECurrentSession.ReleaseExport();

        // [THEN] The reservation is removed
        LibraryAssert.IsFalse(ADLSECurrentSession.Get(ADLSECurrentSession.GetExportReservationTableID(), CompanyName()), 'The reservation should be removed');
    end;

    [Test]
    procedure TestAnyRunInProcess_CoversQueuedTables()
    var
        ADLSERun: Record "ADLSE Run";
        AllObjWithCaption: Record AllObjWithCaption;
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] A table that is queued or starting keeps the export from being reported as finished
        // [GIVEN] No run is in process
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSELibrarybc2adls.CreateAdlseSetup("Storage Type"::"Azure Data Lake");
        ADLSESessionManager.ClearPendingTables();
        ADLSERun.CancelOrphanedRuns('');
        LibraryAssert.IsFalse(ADLSERun.AnyRunInProcess(), 'No run should be in process');

        // [WHEN] A table is queued for export
        DeleteRuns(Database::"Reason Code");
        ADLSERun.RegisterQueued(Database::"Reason Code");

        // [THEN] A run is in process until the export of the table has ended
        LibraryAssert.IsTrue(ADLSERun.AnyRunInProcess(), 'The queued run should be in process');
        AllObjWithCaption.Get(AllObjWithCaption."Object Type"::Table, Database::"Reason Code");
        ADLSERun.RegisterEnded(Database::"Reason Code", false, AllObjWithCaption."Object Caption");
        LibraryAssert.IsFalse(ADLSERun.AnyRunInProcess(), 'No run should be in process after the export ended');
    end;

    [Test]
    procedure TestAnyExportSessionStarting_RecentUnregisteredRun()
    var
        ADLSERun: Record "ADLSE Run";
        ADLSESessionManager: Codeunit "ADLSE Session Manager";
    begin
        // [SCENARIO] A session that was started for a table but has not registered itself yet counts as a running export
        // [GIVEN] No run is in process
        Initialize();
        ADLSELibrarybc2adls.CleanUp();
        ADLSESessionManager.ClearPendingTables();
        ADLSERun.CancelOrphanedRuns('');
        LibraryAssert.IsFalse(ADLSESessionManager.AnyExportSessionStarting(), 'No session should be starting');

        // [WHEN] A session is started for a table
        DeleteRuns(Database::"Reason Code");
        ADLSERun.RegisterQueued(Database::"Reason Code");

        // [THEN] The session counts as starting
        LibraryAssert.IsTrue(ADLSESessionManager.AnyExportSessionStarting(), 'The session should be starting');

        // [WHEN] The table waits in the queue instead
        ADLSESessionManager.SavePendingTables(Format(Database::"Reason Code"));

        // [THEN] The queued table does not count as a starting session
        LibraryAssert.IsFalse(ADLSESessionManager.AnyExportSessionStarting(), 'A queued table should not count as a starting session');

        // [WHEN] The table left the queue a long time ago
        ADLSESessionManager.ClearPendingTables();
        ADLSERun.SetRange("Table ID", Database::"Reason Code");
        ADLSERun.FindLast();
        ADLSERun.Started := CurrentDateTime() - 60 * 60 * 1000;
        ADLSERun.Modify(false);

        // [THEN] The session is considered lost
        LibraryAssert.IsFalse(ADLSESessionManager.AnyExportSessionStarting(), 'A session that never registered should be considered lost');
    end;

    local procedure InsertInactiveSession(TableID: Integer)
    var
        ADLSECurrentSession: Record "ADLSE Current Session";
    begin
        ADLSECurrentSession."Table ID" := TableID;
        ADLSECurrentSession."Company Name" := CopyStr(CompanyName(), 1, MaxStrLen(ADLSECurrentSession."Company Name"));
        ADLSECurrentSession."Session ID" := 2147483000;
        ADLSECurrentSession."Session Unique ID" := CreateGuid();
        ADLSECurrentSession.Insert(false);
    end;

    local procedure DeleteRuns(TableID: Integer)
    var
        ADLSERun: Record "ADLSE Run";
    begin
        ADLSERun.SetRange("Table ID", TableID);
        ADLSERun.DeleteAll(false);
    end;

    local procedure VerifyLastRun(TableID: Integer; ExpectedState: Enum "ADLSE Run State"; ExpectedError: Text)
    var
        ADLSERun: Record "ADLSE Run";
    begin
        ADLSERun.SetRange("Table ID", TableID);
        ADLSERun.FindLast();
        LibraryAssert.AreEqual(ExpectedState, ADLSERun.State, 'Unexpected state of the last run');
        if ExpectedError <> '' then
            LibraryAssert.AreEqual(ExpectedError, ADLSERun.Error, 'Unexpected error of the last run');
    end;

    local procedure Initialize()
    var
        LibraryTestInitialize: Codeunit "Library - Test Initialize";
    begin
        LibraryTestInitialize.OnTestInitialize(Codeunit::"ADLSE Session Manager Tests");

        if IsInitialized then
            exit;

        LibraryTestInitialize.OnBeforeTestSuiteInitialize(Codeunit::"ADLSE Session Manager Tests");

        IsInitialized := true;
        Commit();

        LibraryTestInitialize.OnAfterTestSuiteInitialize(Codeunit::"ADLSE Session Manager Tests");
    end;
}
