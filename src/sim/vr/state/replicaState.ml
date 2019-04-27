module ReplicaState (StateMachine : StateMachine.StateMachine_type) = struct

  type status =
    | Normal
    | ViewChange
    | Recovering

  type replica_state = {
    (* protocol state *)
    configuration : int list;
    replica_no : int;
    view_no : int;
    status: status;
    op_no : int;
    log: (StateMachine.operation * int * int) list;
    commit_no : int;
    client_table: (int * StateMachine.result option) list;

    (* list of operations depending on previous operations not yet seen *)
    queued_prepares : (StateMachine.operation * int * int) option list;
    (* for each not yet committed operation, the number of prepareoks received *)
    waiting_prepareoks : int list;
    (* for each replica, the highest op_no seen in a prepareok message *)
    casted_prepareoks : int list;
    (* the higest commit_no seen in a prepare/commit message *)
    highest_seen_commit_no : int;

    (* number of startviewchange messages received from different replicas *)
    no_startviewchanges : int;
    (* for each replica, indicates whether this has received a startviewchange from them *)
    received_startviewchanges : bool list;
    (* list of doviewchange messages received *)
    doviewchanges : (int * (StateMachine.operation * int * int) list * int * int * int * int) list;
    (* view_no of the last view for which status was normal *)
    last_normal_view_no : int;

    (* the nonce used in this replica's most recent recovery *)
    recovery_nonce : int; 
    (* number of recoveryresponse messages received from different replicas *)
    no_recoveryresponses : int;
    (* for each replica, indicates whether this has received a recoveryresponse from them *)
    received_recoveryresponses : bool list;
    (* recoveryresponse message from primary of latest view seen in recoveryresponse messages *)
    primary_recoveryresponse : (int * int * (StateMachine.operation * int * int) list * int * int * int) option;

    (* increment on recovery and view change *)
    valid_timeout : int;
    (* if primary: no. communications sent, else: no. communications received from primary*)
    no_primary_comms : int;

    (* replicated state machine *)
    mach : StateMachine.t;

    (* safety monitor *)
    monitor : (VR_Safety_Monitor.s list * VR_Safety_Monitor.t);

    (* time *)
    clock : float;

    (* timestamped leases from other replicas *)
    received_leases : float list;
    (* last lease sent to primary *)
    sent_lease : float;
    (* how long leases should last *)
    lease_time : float;
  }

  type replica_message =
    | Request of StateMachine.operation * int * int
    | Prepare of int * (StateMachine.operation * int * int) * int * int
    | PrepareOk of int * int * int * float
    | Commit of int * int
    | StartViewChange of int * int
    | DoViewChange of int * (StateMachine.operation * int * int) list * int * int * int * int
    | StartView of int * (StateMachine.operation * int * int) list * int * int
    | Recovery of int * int
    | RecoveryResponse of int * int * ((StateMachine.operation * int * int) list * int * int) option * int
    | ClientRecovery of int
    | GetState of int * int * int
    | NewState of int * (StateMachine.operation * int * int) list * int * int

  type replica_timeout = 
    | HeartbeatTimeout of int * int
    | PrepareTimeout of int * int
    | PrimaryTimeout of int * int
    | StateTransferTimeout of int * int
    | StartViewChangeTimeout of int
    | DoViewChangeTimeout of int
    | RecoveryTimeout of int
    | GetStateTimeout of int * int
    | LeaseExpired of int * float

  let init_replicas_with_lease_time n_replicas n_clients lease_time = 
    let rec init n_r l =
      if n_r < 0 then
        l
      else
        let state = {
          configuration = List.init n_replicas (fun i -> i);
          replica_no = n_r;
          view_no = 0;
          status = Normal;
          op_no = -1;
          log = [];
          commit_no = -1;
          client_table = List.init n_clients (fun _ -> (-1, None));

          queued_prepares = [];
          waiting_prepareoks = [];
          casted_prepareoks = List.init n_replicas (fun _ -> -1);
          highest_seen_commit_no = -1;

          no_startviewchanges = 0;
          received_startviewchanges = List.init n_replicas (fun _ -> false);
          doviewchanges = [];
          last_normal_view_no = 0;

          recovery_nonce = -1;
          no_recoveryresponses = 0;
          received_recoveryresponses = List.init n_replicas (fun _ -> false);
          primary_recoveryresponse = None;

          valid_timeout = 0;
          no_primary_comms = 0;

          mach = StateMachine.create ();

          monitor = ([], VR_Safety_Monitor.init ~q:(n_replicas / 2 + 1));

          clock = 0.;

          received_leases = List.init n_replicas (fun _ -> -1.);
          sent_lease = -1.;
          lease_time = lease_time;
        } in
        init (n_r - 1) (state::l) in
    init (n_replicas - 1) []

  let crash_replica state = 
    let n_replicas = List.length state.configuration in
    let n_clients = List.length state.client_table in
    let (statecalls, _) = state.monitor in
    {
      configuration = state.configuration;
      replica_no = state.replica_no;
      view_no = 0;
      status = Normal;
      op_no = -1;
      log = [];
      commit_no = -1;
      client_table = List.init n_clients (fun _ -> (-1, None));

      queued_prepares = [];
      waiting_prepareoks = [];
      casted_prepareoks = List.init n_replicas (fun _ -> -1);
      highest_seen_commit_no = -1;

      no_startviewchanges = 0;
      received_startviewchanges = List.init n_replicas (fun _ -> false);
      doviewchanges = [];
      last_normal_view_no = 0;

      recovery_nonce = state.recovery_nonce;
      no_recoveryresponses = 0;
      received_recoveryresponses = List.init n_replicas (fun _ -> false);
      primary_recoveryresponse = None;

      valid_timeout = state.valid_timeout;
      no_primary_comms = 0;

      mach = StateMachine.create ();

      monitor = (statecalls, VR_Safety_Monitor.init ~q:(n_replicas / 2 + 1));

      clock = 0.;

      received_leases = List.init n_replicas (fun _ -> -1.);
      sent_lease = -1.;
      lease_time = state.lease_time;
    }

  let index_of_replica state = state.replica_no

end
