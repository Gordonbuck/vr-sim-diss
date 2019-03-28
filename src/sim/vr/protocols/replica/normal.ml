open Core
open VR_State
open StateTransfer

let start_replica state = 
  if is_primary state then
    (state, [Timeout(ReplicaTimeout(HeartbeatTimeout(valid_timeout state, op_no state), int_of_index (replica_no state)))], Null)
  else
    (state, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), int_of_index (replica_no state)))], Null)

let on_request state op c s =
  let trace_event = "received request" in
  if (is_primary state && (status state) = Normal) then
    let (cte_s, res_opt) = get_client_table_entry state c in
    if (s < cte_s) then
      (* drop request *) 
      let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "request number less than most recent") in
      (state, [], trace)
    else if (s = cte_s) then
      (* request already being/been executed, try to return result *)
      match res_opt with
      | None -> (* no result to return *) 
        let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "most recent request, not yet executed") in
        (state, [], trace)
      | Some(res) -> (* return result for most recent operation *) 
        let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "most recent request, already executed, resend reply") in
        (state, [Communication(Unicast(ClientMessage(Reply(view_no state, s, res)), int_of_index c))], trace)
    else 
      let state = log_request state op c s in
      let broadcast_prepare = Broadcast(ReplicaMessage(Prepare(view_no state, (op, c, s), op_no state, commit_no state))) in
      let prepare_timeout = ReplicaTimeout(PrepareTimeout(valid_timeout state, op_no state), int_of_index (replica_no state)) in
      let heartbeat_timeout = ReplicaTimeout(HeartbeatTimeout(valid_timeout state, op_no state), int_of_index (replica_no state)) in
      let trace = ReplicaTrace(int_of_index (replica_no state), n_replicas state, state, trace_event, "new request, broadcasting prepare") in
      (state, [Communication(broadcast_prepare); Timeout(heartbeat_timeout); Timeout(prepare_timeout)], trace)
  else
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "not primary / normal status") in
    (state, [], trace)

let on_prepare state v (op, c, s) n k = 
  let trace_event = "received prepare" in
  if (status state) <> Normal || v < (view_no state) then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "not normal status / old view number") in
    (state, [], trace)
  else if v > (view_no state) then
    later_view state v trace_event
  else
    let primary_no = primary_no state in
    let state = increment_primary_comms state in
    let primary_timeout = ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), int_of_index (replica_no state)) in
    if (op_no state) >= n then
      (* already prepared request so re-send prepareok *)
      let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "already prepared, resend prepareok") in
      let communication = Unicast(ReplicaMessage(PrepareOk(view_no state, op_no state, replica_no state)), int_of_index primary_no) in
      (state, [Communication(communication); Timeout(primary_timeout)], trace)
    else
      let state = queue_prepare state n (op, c, s) in
      let state = process_queued_prepares state in
      let (n_packets, events, trace_details) = 
        if (op_no state) >= n then 
          (1, [Communication(Unicast(ReplicaMessage(PrepareOk(view_no state, op_no state, replica_no state)), int_of_index primary_no))],
           "successfully prepared, sending prepareok")
        else 
          (0, [Timeout(ReplicaTimeout(StateTransferTimeout(valid_timeout state, op_no state), int_of_index (replica_no state)))],
          "waiting on earlier prepares") in
      let (state, _) = commit state k in
      let trace = ReplicaTrace(int_of_index (replica_no state), n_packets, state, trace_event, trace_details) in
      (state, Timeout(primary_timeout)::events, trace)

let on_prepareok state v n i = 
  let trace_event = "received prepareok" in
  if (status state) <> Normal || v < (view_no state) then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "not normal status / old view number") in
    (state, [], trace)
  else if v > (view_no state) then
    later_view state v trace_event
  else
    let casted_prepareok = get_casted_prepareok state i in
    if casted_prepareok >= n || (commit_no state) >= n then
      (* either already received a prepareok from this replica or already committed operation *)
      let trace_details = if casted_prepareok >= n then "already received prepareok from this replica" else "already commited op" in
      let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, trace_details) in
      (state, [], trace)
    else
      let state = log_prepareok state i n in
      let (state, k) = process_waiting_prepareoks state in
      let (state, replies) = commit state k in
      let comms = List.map replies (fun c -> Communication(c)) in
      let trace_details = if (List.length comms) > 0 then "logged prepareok, sending replies" else "logged prepareok, waiting on other replicas" in
      let trace = ReplicaTrace(int_of_index (replica_no state), (List.length comms), state, trace_event, trace_details) in
      (state, comms, trace)
    
let on_commit state v k = 
  let trace_event = "received commit" in
  if (status state) <> Normal || v < (view_no state) then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "not normal status / old view number") in
    (state, [], trace)
  else if v > (view_no state) then
    later_view state v trace_event
  else
    let state = increment_primary_comms state in
    let (state, _) = commit state k in
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "commited operations") in
    (state, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), int_of_index (replica_no state)))], trace)
