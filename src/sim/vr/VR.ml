open Core

type version = Base | FastReads of float

module type Protocol = sig
  type replica_state
  type client_state
  type replica_message
  type client_message
  type replica_timeout = VR_State.replica_timeout
  type client_timeout = VR_State.client_timeout
  type message = ReplicaMessage of replica_message | ClientMessage of client_message
  type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list
  type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int
  type protocol_event = Communication of communication | Timeout of timeout

  type trace
  type trace_level = VR_State.trace_level

  val on_replica_message: replica_message -> replica_state -> replica_state * protocol_event list * trace
  val on_replica_timeout: replica_timeout -> replica_state -> replica_state * protocol_event list * trace
  val init_replicas: int -> int -> replica_state list
  val crash_replica: replica_state -> replica_state
  val start_replica: replica_state -> replica_state * protocol_event list * trace
  val recover_replica: replica_state -> replica_state * protocol_event list * trace
  val index_of_replica: replica_state -> int
  val check_consistency: replica_state list -> bool
  val replica_is_recovering: replica_state -> bool
  val replica_set_time: replica_state -> float -> replica_state

  val on_client_message: client_message -> client_state -> client_state * protocol_event list * trace
  val on_client_timeout: client_timeout -> client_state -> client_state * protocol_event list * trace
  val init_clients: int -> int -> client_state list
  val crash_client: client_state -> client_state
  val start_client: client_state -> client_state * protocol_event list * trace
  val recover_client: client_state -> client_state * protocol_event list * trace
  val index_of_client: client_state -> int
  val gen_workload: client_state -> int -> client_state
  val finished_workloads: client_state list -> bool
  val client_is_recovering: client_state -> bool
  val client_set_time: client_state -> float -> client_state

  val string_of_trace: trace -> trace_level -> string
end

let build_protocol ver = (module struct 
  include VR_State
  include ClientNormal
  include ClientRecovery
  include Normal
  include Recovery
  include StateTransfer
  include ViewChange
  include ClientTimeouts
  include ReplicaTimeouts

  let my_on_request = 
    match ver with
    | Base -> on_request
    | FastReads(_) -> fr_on_request

  let init_replicas n_replicas n_clients = 
    match ver with
    | Base -> init_replicas_with_lease_time n_replicas n_clients 0.
    | FastReads(lease_time) -> init_replicas_with_lease_time n_replicas n_clients lease_time

  let on_replica_message msg state = 
    match msg with
    | Request(op, c, s) -> my_on_request state op c s
    | Prepare(v, (op, c, s), n, k) -> on_prepare state v (op, c, s) n k
    | PrepareOk(v, n, i, l) -> on_prepareok state v n i l
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
    | LeaseExpired(v, l) -> on_expired_lease state v l

  let on_client_timeout timeout state =
    match timeout with
    | RequestTimeout(v) -> on_request_timeout state v
    | ClientRecoveryTimeout(v) -> on_clientrecovery_timeout state v

  let start_client = start_sending

  let recover_replica = begin_recovery
  let recover_client = begin_clientrecovery

  let replica_is_recovering state = (status state) = Recovering
  let client_is_recovering = client_recovering

  let compare_logs log1 log2 = 
    let rec compare_logs rlog1 rlog2 = 
      match rlog1 with
      | [] -> Some(log2)
      | r1::rlog1 ->
        match rlog2 with
        | [] -> Some(log1)
        | r2::rlog2 ->
          if r1 = r2 then
            compare_logs rlog1 rlog2
          else
            None in
    compare_logs log1 log2

  let check_consistency replicas = 
    let rec inner replicas log1 = 
      match replicas with
      | [] -> true
      | (r::replicas) ->
        let log2 = commited_requests r in
        let larger_log_opt = compare_logs log1 log2 in
        match larger_log_opt with
        | None -> false
        | Some(log) -> inner replicas log in
    inner replicas []

  let rec finished_workloads clients = 
    match clients with
    | [] -> true
    | (c::clients) -> (finished_workload c) && (finished_workloads clients)

  let string_of_replica_state state = 
    let rec string_of_client_table ct c str = 
      match ct with
      | [] -> String.concat([str; "]"])
      | (s, _)::ct -> string_of_client_table ct (c+1) (String.concat ([(Printf.sprintf "(%i,%i)" c (int_of_index s));str])) in
    let rec string_of_log log str = 
      match log with
      | [] -> String.concat ([str; "]"])
      | (op, c, s)::log -> string_of_log log (String.concat ([(Printf.sprintf "(%i,%i)" (int_of_index c) (int_of_index s));str])) in
    let log = log state in
    let commit_no = commit_no state in
    let ct = client_table state in
    let view_no = view_no state in
    String.concat (["[";(string_of_log log "");" [";(string_of_client_table ct 0 "");Printf.sprintf " commit_no %i" (int_of_index commit_no);Printf.sprintf " view_no %i" (int_of_index view_no)])

  let string_of_trace trace level = 
    match trace with
    | ReplicaTrace(i, n_packets, state, event, response) -> (
      match level with
      | High -> Printf.sprintf "replica %i; %s; %s; %i packets sent; %s" i event response n_packets (string_of_replica_state state)
      | Medium -> Printf.sprintf "replica %i; %s; %s; %i packets sent" i event response n_packets
      | Low -> Printf.sprintf "replica %i; %s" i event)
    | ClientTrace(i, n_packets, state, event, response) -> (
      match level with
      | High -> Printf.sprintf "client %i; %s; %s; %i packets sent" i event response n_packets
      | Medium -> Printf.sprintf "client %i; %s; %s; %i packets sent" i event response n_packets
      | Low -> Printf.sprintf "client %i; %s" i event)
    | Null -> ""

end : Protocol)
