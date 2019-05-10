open Core
open VR_State

let begin_statetransfer state trace_event trace_details = 
  let state = update_monitor state `Send_Getstate in
  let primary_no = primary_no state in
  let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, trace_details) in
  (state, [Communication(Unicast(ReplicaMessage(GetState(view_no state, op_no state, replica_no state)), int_of_index primary_no));
           Timeout(ReplicaTimeout(GetStateTimeout(valid_timeout state, op_no state), int_of_index (replica_no state)))], trace)

let later_view state v trace_event = 
  let state = rollback_to_commit state in
  let state = set_view_no state v in
  begin_statetransfer state trace_event "noticed later view, sending get state message"

let on_getstate state v n' i = 
  let trace_event = "received get state" in
  if (status state) <> Normal || (view_no state) <> v then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "not normal status / different view number") in
    (state, [], trace)
  else
    let state = update_monitor state `Deliver_Getstate in
    let state = update_monitor state `Send_Newstate in
    let log = log_suffix state n' in
    let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "sending new state") in
    (state, [Communication(Unicast(ReplicaMessage(NewState(view_no state, log, op_no state, commit_no state)), int_of_index i))], trace)

let on_newstate state v l n k =
  let trace_event = "received new state" in
  if n <= (op_no state) || (status state) <> Normal || (view_no state) <> v then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "not normal status / different view number / old state") in
    (state, [], trace)
  else
    let state = update_monitor state `Deliver_Newstate in
    let state = append_log state l n in
    let state = set_op_no state n in
    let (state, _) = commit state k in
    let state = increment_primary_comms state in
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "appended log") in
    (state, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), int_of_index (replica_no state)))], trace)
