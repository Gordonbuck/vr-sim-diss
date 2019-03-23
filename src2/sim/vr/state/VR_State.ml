module StateMachine = StateMachine.KeyValueStore

open ReplicaState.ReplicaState(StateMachine)
open ClientState.ClientState(StateMachine)

type message = ReplicaMessage of replica_message | ClientMessage of client_message
type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list
type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int
type protocol_event = Communication of communication | Timeout of timeout

let is_primary state = state.view_no mod (List.length state.configuration) = state.replica_no

let primary_no state = state.view_no mod (List.length state.configuration)

let view_no state = state.view_no

let replica_no state = state.replica_no

let op_no state = state.op_no

let commit_no state = state.commit_no

let status state = state.status

let get_client_table_entry state c = 
  let cte_opt = List.nth state.client_table c in
  match cte_opt with 
  | None -> (* no client table entry for this client id *) assert(false)
  | Some(s, res_opt) -> (s, res_opt)

let valid_timeout state = state.valid_timeout

let no_primary_comms state = state.no_primary_comms

let get_casted_prepareok state i =
  let casted_prepareok_opt = List.nth state.casted_prepareoks i in
  match casted_prepareok_opt with
  | None -> (* no such replica *) assert(false)
  | Some(casted_prepareok) -> casted_prepareok

let increment_primary_comms state = 
  let no_primary_comms = state.no_primary_comms + 1 in
  {state with no_primary_comms = no_primary_comms; }

let update_client_table ?(res=None) state c s = 
  let client_table  = List.mapi state.client_table (fun i cte -> if i = c then (s, res) else cte) in
  {state with client_table = client_table; }

let rec update_client_table_requests state reqs = 
  match reqs with
  | (op, c, s)::reqs -> update_client_table_requests (update_client_table state c s) reqs
  | [] -> state

let log_request state op c s = 
  let op_no = state.op_no + 1 in
  let log = (op, c, s)::state.log in
  let waiting_prepareoks = 0::state.waiting_prepareoks in
  let state = update_client_table state c s in
  {state with 
   op_no = op_no;
   log = log;
   client_table = client_table;
   waiting_prepareoks = waiting_prepareoks;
  }

let queue_prepare state n (op, c, s) = 
  let no_queued = List.length state.queued_prepares in
  let index = state.op_no + no_queued - n in
  let queued_prepares = 
    if (index >= 0) then 
      List.mapi state.queued_prepares (fun i req_opt -> if i = index then Some((op, c, s)) else req_opt)
    else 
      Some((op, c, s))::(add_nones state.queued_prepares (-(index + 1))) in  
  {state with queued_prepares = queued_prepares; }

let process_queued_prepares state = 
  let rec process_queued_prepares rev_queued_prepares prepared =
    match rev_queued_prepares with
    | (None::_) | [] -> (rev_queued_prepares, prepared)
    | (Some(req)::rev_queued_prepares) -> process_queued_prepares rev_queued_prepares (req::prepared) in
  let (rev_queued_prepares, prepared) = process_queued_prepares (List.rev state.queued_prepares) [] in
  let queued_prepares = List.rev rev_queued_prepares in
  let op_no = state.op_no + List.length prepared in
  let log = List.append prepared state.log in
  let client_table = update_ct_reqs state.client_table (List.rev prepared) in
  {state with 
   op_no = op_no;
   log = log;
   client_table = client_table;
   queued_prepares = queued_prepares;
  }

let commit state k =
  let rec commit_all mach ct reqs replies = 
    match reqs with 
    | (op, c, s)::reqs -> 
      let mach = StateMachine.apply_op mach op in
      let res = StateMachine.last_res mach in
      let ct = update_ct ct c s ~res:(Some(res)) in
      commit_all mach ct reqs (Unicast(ClientMessage(Reply(state.view_no, s, res)), c)::replies)
    | [] -> (mach, ct, replies) in
  let k = max state.highest_seen_commit_no k in
  let commit_until = ((List.length state.log) - 1 - k) in
  let last_committed_index = (List.length state.log) - 1 - state.commit_no in
  let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
  let (mach, client_table, replies) = commit_all state.mach state.client_table (List.rev to_commit) [] in
  let commit_no = state.commit_no + (List.length to_commit) in
  ({state with 
    commit_no = commit_no;
    client_table = client_table;
    highest_seen_commit_no = k;
    mach = mach;
   }, replies)

let increment_prepareoks state i n =
  let f = ((List.length state.configuration) / 2) in
  let no_waiting = List.length state.waiting_prepareoks in
  let index = state.commit_no + no_waiting - n in
  let last_casted_index = state.commit_no + no_waiting - casted_prepareok in
  let waiting_prepareoks = List.mapi state.waiting_prepareoks (fun i w -> if i >= index && i < last_casted_index then w+1 else w) in
  let casted_prepareoks = List.mapi state.casted_prepareoks (fun idx m -> if idx = i then n else m) in
  {state with 
   waiting_prepareoks = waiting_prepareoks;
   casted_prepareoks = casted_prepareoks;
  }

let process_waiting_prepareoks state = 
  let f = ((List.length state.configuration) / 2) in
  let rec process_waiting_prepareoks rev_waiting_prepareoks n = 
    match rev_waiting_prepareoks with
    | [] -> (rev_waiting_prepareoks, n)
    | w::rev_waiting_prepareoks -> 
      if w < f then 
        (w::rev_waiting_prepareoks, n)
      else 
        process_waiting_prepareoks rev_waiting_prepareoks (n+1) in
  let (rev_waiting_prepareoks, rev_index) = process_waiting_prepareoks (List.rev state.waiting_prepareoks) (-1) in
  let waiting_prepareoks = List.rev rev_waiting_prepareoks in
  let k = state.commit_no + rev_index + 1 in
  ({state with
    waiting_prepareoks = waiting_prepareoks;
   }, k)
