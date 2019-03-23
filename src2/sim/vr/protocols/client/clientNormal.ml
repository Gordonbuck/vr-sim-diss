open Core
open VR_State

let start_sending state =
  let (state, op_opt) = next_operation state in
  match op_opt with
  | None -> (* no operations left *) (state, [])
  | Some(op) -> (* send next request *)
    let primary_no = client_primary_no state in
    (state, [Communication(Unicast(ReplicaMessage(Request(op, client_id state, client_request_no state)), primary_no)); 
             Timeout(ClientTimeout(RequestTimeout(client_valid_timeout state), client_id state))])

let on_reply state v s res = 
  if s < (client_request_no state) || (client_recovering state) then
    (* already received this reply or recovering so cant proceed *)
    (state, [])
  else
    let state = client_set_view_no state v in
    start_sending state
