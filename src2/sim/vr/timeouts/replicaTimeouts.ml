open Core
open VR_State
open StateTransfer
open ViewChange

let on_heartbeat_timeout state v n = 
  if (valid_timeout state) = v && (op_no state) = n then
    (* send commit message as heartbeat *)
    (state, [Communication(Broadcast(ReplicaMessage(Commit(view_no state, commit_no state)))); 
             Timeout(ReplicaTimeout(HeartbeatTimeout(valid_timeout state, op_no state), replica_no state))])
  else
    (state, [])

let on_prepare_timeout state v k = 
  if (valid_timeout state) = v && (commit_no state) < k then
    (* havent committed the operation yet *)
    let req = get_request state k in
    let indices = waiting_on_prepareoks state k in
    let multicast = Multicast(ReplicaMessage(Prepare(view_no state, req, k, commit_no state)), indices) in
    let prepare_timeout = ReplicaTimeout(PrepareTimeout(valid_timeout state, k), replica_no state) in
    (state, [Communication(multicast); Timeout(prepare_timeout)])
  else
    (state, [])
    
let on_primary_timeout state v n = 
  if (valid_timeout state) = v && (no_primary_comms state) = n then
    (* no communication from primary since last timeout check, start viewchange *)
    notice_viewchange state
  else
    (state, [])

let on_statetransfer_timeout state v n = 
  if (valid_timeout state) = v && (op_no state) <= n then
    (* haven't received missing prepare message, initiate state transfer *)
    begin_statetransfer state
  else
    (state, [])

let on_startviewchange_timeout state v = 
  if (valid_timeout state) = v then
    (* re-send startviewchange messages to non-responsive replicas *)
    let indices = waiting_on_startviewchanges state in
    let multicast = Multicast(ReplicaMessage(StartViewChange(view_no state, replica_no state)), indices) in
    (state, [Communication(multicast); Timeout(ReplicaTimeout(StartViewChangeTimeout(valid_timeout state), replica_no state))])
  else 
    (state, [])

let on_doviewchange_timeout state v = 
  if (valid_timeout state) = v then
    (* re-send doviewchange message to primary *)
    let primary_no = primary_no state in
    let msg = DoViewChange(view_no state, log state, last_normal_view_no state, op_no state, commit_no state, replica_no state) in
    (state, [Communication(Unicast(ReplicaMessage(msg), primary_no)); 
             Timeout(ReplicaTimeout(DoViewChangeTimeout(valid_timeout state), replica_no state))])
  else
    (state, [])

let on_recovery_timeout state v = 
  if state.valid_timeout = v then
    (* re-send recovery messages to non-responsive replicas *)
    let indices = waiting_on_recoveryresponses state in
    let multicast = Multicast(ReplicaMessage(Recovery(replica_no state, current_recovery_nonce state)), indices) in
    (state, [Communication(multicast); Timeout(ReplicaTimeout(RecoveryTimeout(valid_timeout state), replica_no state))])
  else 
    (state, [])

let on_getstate_timeout state v n =
  if (valid_timeout state) = v && (op_no state) <= n then
    (* havent updated log since request for more state, re-send request *)
    let primary_no = primary_no state in
    (state, [Communication(Unicast(ReplicaMessage(GetState(view_no state, op_no state, replica_no state)), primary_no));
             Timeout(ReplicaTimeout(GetStateTimeout(valid_timeout state, op_no state), replica_no state))])
  else
    (state, [])
