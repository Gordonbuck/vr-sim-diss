open Core
open VR_State
open StateTransfer

let start_replica state = 
  if is_primary state then
    (state, [Timeout(ReplicaTimeout(HeartbeatTimeout(valid_timeout state, op_no state), replica_no state))])
  else
    (state, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), replica_no state))])

let on_request state op c s =
  if (is_primary state && (status state) = Normal) then
    let (cte_s, res_opt) = get_client_table_entry state c in
    if (s < cte_s) then
      (* drop request *) (state, [])
    else if (s = cte_s) then
      (* request already being/been executed, try to return result *)
      match res_opt with
      | None -> (* no result to return *) (state, [])
      | Some(res) -> (* return result for most recent operation *) 
        (state, [Communication(Unicast(ClientMessage(Reply(view_no state, s, res)), c))])
    else 
      let state = log_request state op c s in
      let broadcast_prepare = Broadcast(ReplicaMessage(Prepare(view_no state, (op, c, s), op_no, commit_no state))) in
      let prepare_timeout = ReplicaTimeout(PrepareTimeout(valid_timeout state, op_no), replica_no state) in
      let heartbeat_timeout = ReplicaTimeout(HeartbeatTimeout(valid_timeout state, op_no), replica_no state) in
      (state, [Communication(broadcast_prepare); Timeout(heartbeat_timeout); Timeout(prepare_timeout)])
  else
    (state, [])

let on_prepare state v (op, c, s) n k = 
  if (status state) <> Normal || v < (view_no state) then
    (state, [])
  else if v > (view_no state) then
    later_view state v
  else
    let primary_no = primary_no state in
    let state = increment_primary_comms state in
    let primary_timeout = ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), replica_no state) in
    if (op_no state) >= n then
      (* already prepared request so re-send prepareok *)
      let communication = Unicast(ReplicaMessage(PrepareOk(view_no state, op_no state, replica_no state)), primary_no) in
      (state, [Communication(communication); Timeout(primary_timeout)])
    else
      let state = queue_prepare state n (op, c, s) in
      let state = process_queued_prepares state in
      let events = 
        if op_no > (op_no state) then 
          [Communication(Unicast(ReplicaMessage(PrepareOk(view_no state, op_no, replica_no state)), primary_no))]
        else 
          [Timeout(ReplicaTimeout(StateTransferTimeout(valid_timeout state, op_no state), replica_no state))] in
      let (state, _) = commit state k in
      (state, Timeout(primary_timeout)::events)

let on_prepareok state v n i = 
  if (status state) <> Normal || v < (view_no state) then
    (state, [])
  else if v > (view_no state) then
    later_view state v
  else
    let casted_prepareok = get_casted_prepareok state i in
    if casted_prepareok >= n || (commit_no state) >= n then
      (* either already received a prepareok from this replica or already committed operation *)
      (state, [])
    else
      let state = log_prepareok state i n in
      let (state, k) = process_waiting_prepareoks state in
      let (state, replies) = commit state k in
      let comms = List.map replies (fun c -> Communication(c)) in
      (state, comms)
    
let on_commit state v k = 
  if (status state) <> Normal || v < (view_no state) then
    (state, [])
  else if v > (view_no state) then
    later_view state v
  else
    let state = increment_primary_comms state in
    let (state, _) = commit state k in
    (state, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), replica_no state))])
