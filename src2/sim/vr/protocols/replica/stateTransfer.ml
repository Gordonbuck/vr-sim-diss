open Core
open VR_State

let begin_statetransfer state = 
  let primary_no = primary_no state in
  (state, [Communication(Unicast(ReplicaMessage(GetState(view_no state, op_no state, replica_no state)), int_of_index primary_no));
           Timeout(ReplicaTimeout(GetStateTimeout(valid_timeout state, op_no state), int_of_index (replica_no state)))])

let later_view state v = 
  let state = rollback_to_commit state in
  let state = set_view_no state v in
  begin_statetransfer state

let on_getstate state v n' i = 
  if (status state) <> Normal || (view_no state) <> v then
    (state, [])
  else
    let log = log_suffix state n' in
    (state, [Communication(Unicast(ReplicaMessage(NewState(view_no state, log, op_no state, commit_no state)), int_of_index i))])

let on_newstate state v l n k =
  if n <= (op_no state) || (status state) <> Normal || (view_no state) <> v then
    (state, [])
  else
    let state = append_log state l n in
    let state = set_op_no state n in
    let (state, _) = commit state k in
    let state = increment_primary_comms state in
    (state, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), int_of_index (replica_no state)))])
