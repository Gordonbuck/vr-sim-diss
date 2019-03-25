open Core
open VR_State
open ClientNormal
open ClientRecovery
open Normal
open Recovery
open StateTransfer
open ViewChange
open ClientTimeouts
open ReplicaTimeouts

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

let start_client = start_sending

let recover_replica = begin_recovery
let recover_client = begin_clientrecovery

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
