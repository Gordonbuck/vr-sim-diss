open Core
open ClientState
open ReplicaState
open VR_Events
open VR_Utils

let start_sending (state : client_state) = 
  let op_opt = List.nth state.operations_to_do state.next_op_index in
  let next_op_index = state.next_op_index + 1 in
  let request_no = state.request_no + 1 in
  let state = {state with 
               request_no = request_no;
               next_op_index = next_op_index;
              } in
  match op_opt with
  | None -> (* no operations left *) (state, [])
  | Some(op) -> (* send next request *) 
    let primary_no = primary_no state.view_no state.configuration in
    (state, [Communication(Unicast(ReplicaMessage(Request(op, state.client_id, request_no)), primary_no)); 
             Timeout(ClientTimeout(RequestTimeout(state.valid_timeout), state.client_id))])

let on_reply state v s res = 
  if s < state.request_no || state.recovering then
    (* already received this reply or recovering so cant proceed *)
    (state, [])
  else
    let valid_timeout = state.valid_timeout + 1 in
    let state = {state with valid_timeout = valid_timeout;} in
    start_sending state
