open Core
open ClientState
open ReplicaState
open VR_Events
open VR_Utils
open ViewChange
open StateTransfer

let on_heartbeat_timeout state v n = 
  if state.valid_timeout = v && state.op_no = n then
    (* send commit message as heartbeat *)
    (state, [Communication(Broadcast(ReplicaMessage(Commit(state.view_no, state.commit_no)))); 
             Timeout(ReplicaTimeout(HeartbeatTimeout(state.valid_timeout, state.op_no), state.replica_no))])
  else
    (state, [])

let on_prepare_timeout state v k = 
  if state.valid_timeout = v && state.commit_no < k then
    (* havent committed the operation yet *)
    let index = List.length state.log - 1 - k in
    let req_opt = List.nth state.log index in
    match req_opt with
    | None -> (* no such request in log, should have been caught by valid timer tag *) assert(false)
    | Some(req) ->
      (* send prepare message to non-responsive replicas *)
      let received_prepareoks = List.map state.casted_prepareoks (fun m -> m >= k) in
      let indices = map_falses received_prepareoks (fun i -> i) in
      let multicast = Multicast(ReplicaMessage(Prepare(state.view_no, req, k, state.commit_no)), indices) in
      let prepare_timeout = ReplicaTimeout(PrepareTimeout(state.valid_timeout, k), state.replica_no) in
      (state, [Communication(multicast); Timeout(prepare_timeout)])
  else
    (state, [])

let on_primary_timeout state v n = 
  if state.valid_timeout = v && state.no_primary_comms = n then
    (* no communication from primary since last timeout check, start viewchange *)
    notice_viewchange state
  else
    (state, [])

let on_statetransfer_timeout state v n = 
  if state.valid_timeout = v && state.op_no <= n then
    (* haven't received missing prepare message, initiate state transfer *)
    begin_statetransfer state
  else
    (state, [])

let on_startviewchange_timeout state v = 
  if state.valid_timeout = v then
    (* re-send startviewchange messages to non-responsive replicas *)
    let indices = map_falses state.received_startviewchanges (fun i -> i) in
    let multicast = Multicast(ReplicaMessage(StartViewChange(state.view_no, state.replica_no)), indices) in
    (state, [Communication(multicast); Timeout(ReplicaTimeout(StartViewChangeTimeout(state.valid_timeout), state.replica_no))])
  else 
    (state, [])

let on_doviewchange_timeout state v = 
  if state.valid_timeout = v then
    (* re-send doviewchange message to primary *)
    let primary_no = primary_no state.view_no state.configuration in
    let msg = DoViewChange(state.view_no, state.log, state.last_normal_view_no, state.op_no, state.commit_no, state.replica_no) in
    (state, [Communication(Unicast(ReplicaMessage(msg), primary_no)); 
             Timeout(ReplicaTimeout(DoViewChangeTimeout(state.valid_timeout), state.replica_no))])
  else
    (state, [])

let on_recovery_timeout state v = 
  if state.valid_timeout = v then
    (* re-send recovery messages to non-responsive replicas *)
    let indices = map_falses state.received_recoveryresponses (fun i -> i) in
    let multicast = Multicast(ReplicaMessage(Recovery(state.replica_no, state.recovery_nonce)), indices) in
    (state, [Communication(multicast); Timeout(ReplicaTimeout(RecoveryTimeout(state.valid_timeout), state.replica_no))])
  else 
    (state, [])

let on_getstate_timeout state v n =
  if state.valid_timeout = v && state.op_no <= n then
    (* havent updated log since request for more state, re-send request *)
    let primary_no = primary_no state.view_no state.configuration in
    (state, [Communication(Unicast(ReplicaMessage(GetState(state.view_no, state.op_no, state.replica_no)), primary_no));
             Timeout(ReplicaTimeout(GetStateTimeout(state.valid_timeout, state.op_no), state.replica_no))])
  else
    (state, [])
