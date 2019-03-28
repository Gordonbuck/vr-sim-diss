open Core
open VR_State

let send (state : client_state) trace_event = 
  let (state, op_opt) = next_operation state in
  match op_opt with
  | None -> (* no operations left *) 
    let trace = ClientTrace(int_of_index (client_id state), 0, state, trace_event, "no operations left") in
    (state, [], trace)
  | Some(op) -> (* send next request *)
    let primary_no = client_primary_no state in
    let trace = ClientTrace(int_of_index (client_id state), 1, state, trace_event, "sending next request to primary") in
        (state, [Communication(Unicast(ReplicaMessage(Request(op, client_id state, client_request_no state)), int_of_index primary_no)); 
                 Timeout(ClientTimeout(RequestTimeout(client_valid_timeout state), int_of_index (client_id state)))], trace) 

let start_sending (state : client_state) =
  send state ("started sending")

let on_reply (state : client_state) v s res = 
  let trace_event = "reply received" in
  if s < (client_request_no state) || (client_recovering state) then
    (* already received this reply or recovering so cant proceed *)
    let details = if (client_recovering state) then "client recovering" else "not for outstanding request" in
    let trace = ClientTrace(int_of_index (client_id state), 0, state, trace_event, details) in
    (state, [], trace)
  else
    let state = client_set_view_no state v in
    send state trace_event
