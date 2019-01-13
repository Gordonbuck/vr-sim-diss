open Core

module type Protocol_type = sig
  type replica_state
  type client_state
  type replica_message
  type client_message
  type replica_timeout
  type client_timeout
  type message = ReplicaMessage of replica_message | ClientMessage of client_message
  type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list
  type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int
  type protocol_event = Communication of communication | Timeout of timeout

  val on_replica_message: replica_message -> replica_state -> replica_state * protocol_event list
  val on_replica_timeout: replica_timeout -> replica_state -> replica_state * protocol_event list
  val init_replicas: int -> int -> replica_state list
  val crash_replica: replica_state -> replica_state
  val start_replica: replica_state -> replica_state * protocol_event list
  val recover_replica: replica_state -> replica_state * protocol_event list
  val index_of_replica: replica_state -> int
  val check_consistency: replica_state list -> bool

  val on_client_message: client_message -> client_state -> client_state * protocol_event list
  val on_client_timeout: client_timeout -> client_state -> client_state * protocol_event list
  val init_clients: int -> int -> client_state list
  val crash_client: client_state -> client_state
  val start_client: client_state -> client_state * protocol_event list
  val recover_client: client_state -> client_state * protocol_event list
  val index_of_client: client_state -> int
  val gen_workload: client_state -> int -> client_state
  val finished_workloads: client_state list -> bool
end

module VR = struct

  include ClientState
  include ReplicaState
  include VR_Events
  include VR_Utils
  include Normal
  include ViewChange
  include Recovery
  include StateTransfer
  include ClientNormal
  include ClientRecovery
  include ReplicaTimeouts
  include ClientTimeouts

  let on_replica_message msg state = 
    match msg with
    | Request(op, c, s) -> on_request state op c s
    | Prepare(v, (op, c, s), n, k) -> on_prepare state v (op, c, s) n k
    | PrepareOk(v, n, i) -> on_prepareok state v n i
    | Commit(v, k) -> on_commit state v k
    | StartViewChange(v, i) -> on_startviewchange state v i
    | DoViewChange(v, l, v', n, k, i) -> on_doviewchange state v l v' n k i
    | StartView(v, l, n, k) -> on_startview state v l n k
    | Recovery(i, x) -> on_recovery state i x
    | RecoveryResponse(v, x, opt_p, j) -> on_recoveryresponse state v x opt_p j
    | GetState(v, n', i) -> on_getstate state v n' i
    | NewState(v, l, n, k) -> on_newstate state v l n k
    | ClientRecovery(c) -> on_clientrecovery state c

  let on_client_message msg state = 
    match msg with
    | Reply(v, s, res) -> on_reply state v s res
    | ClientRecoveryResponse(v, s, i) -> on_clientrecoveryresponse state v s i

  let on_replica_timeout timeout state = 
    match timeout with
    | HeartbeatTimeout(v, n) -> on_heartbeat_timeout state v n
    | PrepareTimeout(v, k) -> on_prepare_timeout state v k
    | PrimaryTimeout(v, n) -> on_primary_timeout state v n
    | StateTransferTimeout(v, n) -> on_statetransfer_timeout state v n
    | StartViewChangeTimeout(v) -> on_startviewchange_timeout state v
    | DoViewChangeTimeout(v) -> on_doviewchange_timeout state v
    | RecoveryTimeout(v) -> on_recovery_timeout state v
    | GetStateTimeout(v, n) -> on_getstate_timeout state v n

  let on_client_timeout timeout state =
    match timeout with
    | RequestTimeout(v) -> on_request_timeout state v
    | ClientRecoveryTimeout(v) -> on_clientrecovery_timeout state v

  let init_replicas n_replicas n_clients = 
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
        } in
        init (n_r - 1) (state::l) in
    init (n_replicas - 1) []

  let init_clients n_replicas n_clients = 
    let rec init n_c l = 
      if n_c < 0 then
        l
      else
        let state = {
          configuration = List.init n_replicas (fun i -> i);
          view_no = 0;
          client_id = n_c;
          request_no = -1;

          next_op_index = 0;
          operations_to_do = [];

          recovering = false;
          no_clientrecoveryresponses = 0;
          received_clientrecoveryresponses = List.init n_replicas (fun _ -> false);

          valid_timeout = 0;
        } in
        init (n_c - 1) (state::l) in
    init (n_clients - 1) []

  let crash_replica state = 
    let n_replicas = List.length state.configuration in
    let n_clients = List.length state.client_table in
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
    }

  let crash_client (state : client_state) =
    let n_replicas = List.length state.configuration in
    {
      configuration = state.configuration;
      view_no = 0;
      client_id = state.client_id;
      request_no = -1;

      next_op_index = state.next_op_index;
      operations_to_do = state.operations_to_do;

      recovering = false;
      no_clientrecoveryresponses = 0;
      received_clientrecoveryresponses = List.init n_replicas (fun _ -> false);

      valid_timeout = state.valid_timeout;
    }

  let recover_replica = begin_recovery
  let recover_client = begin_clientrecovery

  let start_replica state = 
    if is_primary state then
      (state, [Timeout(ReplicaTimeout(HeartbeatTimeout(state.valid_timeout, state.op_no), state.replica_no))])
    else
      (state, [Timeout(ReplicaTimeout(PrimaryTimeout(state.valid_timeout, state.no_primary_comms), state.replica_no))])

  let start_client = start_sending

  let gen_workload state n = {state with operations_to_do = StateMachine.gen_ops n;}

  let index_of_replica state = state.replica_no

  let index_of_client state = state.client_id

  let print_log log = 
    let rec inner log = 
      match log with
      | [] -> ()
      | (_, c, s)::[] -> Printf.printf "(%i, %i)" c s
      | (_, c, s)::log -> Printf.printf "(%i, %i) " c s; inner log in
    Printf.printf "["; inner log; Printf.printf "]\n"

  let check_consistency replicas = 
    let rec inner replicas log1 = 
      match replicas with
      | [] -> true
      | (r::replicas) ->
        let log2 = commited_requests r.commit_no r.log in
        let larger_log_opt = compare_logs log1 log2 in
        Printf.printf "Replica %i, commit_no %i, log: " r.replica_no r.commit_no;
        print_log r.log;
        match larger_log_opt with
        | None -> false
        | Some(log) -> inner replicas log in
    inner replicas []

  let finished_workloads clients = 
    let rec inner clients = 
      match clients with
      | [] -> true
      | (c::clients) -> 
        if (c.next_op_index < (List.length c.operations_to_do) + 1) then false
        else inner clients in
    inner clients

end
