open Core

module StateMachine = StateMachine.KeyValueStore

type client_message =
  | Request of StateMachine.operation * int * int
  | UpdateRequestNumber

type replica_message =
  | Prepare of int * client_message * int * int
  | PrepareOk of int * int * int
  | Reply of int * int * StateMachine.result
  | Commit of int * int
  | StartViewChange
  | DoViewChange
  | StartView
  | Recovery
  | RecoveryResponse
  | GetState
  | NewState

type status =
  | Normal
  | ViewChange
  | Recovering

type state = {
  configuration : int list;
  replica_no : int;
  view_no : int;
  status: status;
  op_no : int;
  log: client_message list;
  commit_no : int;
  client_table: (int * StateMachine.result option) list;

  queued_prepares : client_message option list;
  waiting_prepareoks : int list;
  mach: StateMachine.t;
}

(* core protocol implementation at replicas *)

let is_primary state = 
  state.view_no mod (List.length state.configuration) = state.replica_no

let update_ct ct c ?(res=None) s = List.mapi ct (fun i cte -> if i = c then (s, res) else cte)

let on_request state op c s =
  if (is_primary state) then
    let cte_opt = List.nth state.client_table c in
    match cte_opt with 
    | None -> (* no client table entry for this client id *) assert(false)
    | Some(cte_s, res_opt) -> 
      if (cte_s = s) then
        (* request already being/been executed, try to return result *)
        match res_opt with
        | None -> (* no result to return *) (state, None)
        | Some(res) -> (* return result for most recent operation *) (state, Some(Reply(state.view_no, s, res)))
      else if (cte_s > s) then
        (* begin protocol to execute new request *)
        let op_no = state.op_no + 1 in
        let request = Request(op, c, s) in
        let log = request::state.log in
        let client_table = update_ct state.client_table c s in
        let waiting_prepareoks = 0::state.waiting_prepareoks in
        ({state with 
          op_no = op_no;
          log = log;
          client_table = client_table;
          waiting_prepareoks = waiting_prepareoks;
         }, Some(Prepare(state.view_no, request, op_no, state.commit_no)))
      else
        (* drop request *) (state, None)
  else
    (state, None)

let process_queued_prepares queued_prepares =
  let rec process_queued_prepares rev_queued_prepares prepared =
    match rev_queued_prepares with
    | (None::_) | [] -> (rev_queued_prepares, prepared)
    | (Some(req)::rev_queued_prepares) -> process_queued_prepares rev_queued_prepares (req::prepared) in
  let (rev_queued_prepares, prepared) = process_queued_prepares (List.rev queued_prepares) [] in
  (List.rev rev_queued_prepares, prepared)

let rec add_nones l n = 
  match n with 
  | _ when n < 1 -> l
  | n -> add_nones (None::l) (n - 1)

let rec update_ct_reqs ct reqs = 
  match reqs with
  | (Request(op, c, s)::reqs) -> update_ct_reqs (update_ct ct c s) reqs
  | _ -> ct

(* on_prepare assumes request being sent isnt already in log *)

let on_prepare state v (op, c, s) n k = 
  let request = Request(op, c, s) in
  let no_queued = List.length state.queued_prepares in
  let index = state.op_no + no_queued - n in
  let queued_prepares = 
    if (index >= 0) then 
      List.mapi state.queued_prepares (fun i req_opt -> if i = index then Some(request) else req_opt)
    else 
      Some(request)::(add_nones state.queued_prepares (-(index + 1))) in    
  let (queued_prepares, prepared) = process_queued_prepares queued_prepares in
  let op_no = state.op_no + List.length prepared in
  let log = List.append prepared state.log in
  let client_table = update_ct_reqs state.client_table (List.rev prepared) in
  let message_opt = if (op_no > state.op_no) then Some(PrepareOk(state.view_no, op_no, state.replica_no)) else None in
  ({state with 
    op_no = op_no;
    log = log;
    client_table = client_table;
    queued_prepares = queued_prepares;
   }, message_opt)

let process_waiting_prepareoks f waiting_prepareoks = 
  let rec process_waiting_prepareoks rev_waiting_prepareoks n = 
    match rev_waiting_prepareoks with
    | [] -> (rev_waiting_prepareoks, n)
    | w::rev_waiting_prepareoks -> 
      if w < f then 
        (w::rev_waiting_prepareoks, n)
      else 
        process_waiting_prepareoks rev_waiting_prepareoks (n+1) in
  let (rev_waiting_prepareoks, rev_index) = process_waiting_prepareoks (List.rev waiting_prepareoks) (-1) in
  (List.rev rev_waiting_prepareoks, (List.length waiting_prepareoks) - 1 - rev_index)

let commit_all view_no mach ct reqs = 
  let rec commit_all mach ct reqs replies = 
    match reqs with 
    | Request(op, c, s)::reqs -> 
      let mach = StateMachine.apply_op mach op in
      let res = StateMachine.last_res mach in
      let ct = update_ct ct c ~res:(Some(res)) s in
      commit_all mach ct reqs (Reply(view_no, s, res)::replies)
    | _ -> (mach, ct, replies) in
  commit_all mach ct reqs []

let on_prepareok state v n i = 
  let f = ((List.length state.configuration) / 2) in
  let no_waiting = List.length state.waiting_prepareoks in
  let index = state.commit_no + no_waiting - n in
  let no_prepareoks_opt = List.nth state.waiting_prepareoks index in
  match no_prepareoks_opt with
  | None -> (* no log entry for that op number *)  assert(false)
  | Some(_) ->
    let waiting_prepareoks = List.mapi state.waiting_prepareoks (fun i w -> if i >= index then w+1 else w) in
    let (waiting_prepareoks, commit_until) = process_waiting_prepareoks f waiting_prepareoks in 
    let last_committed_index = (List.length state.log) - 1 - state.commit_no in
    let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
    let (mach, client_table, replies) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
    let commit_no = state.commit_no + (List.length to_commit) in
    ({state with 
      commit_no = commit_no;
      client_table = client_table;
      waiting_prepareoks = waiting_prepareoks;
      mach = mach;
     }, List.map replies (fun r -> Some(r)))

let on_commit state v k = 
  let commit_until = (List.length state.log) - 1 - k in
  let last_committed_index = (List.length state.log) - 1 - state.commit_no in
  let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
  let (mach, client_table, _) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
  let commit_no = state.commit_no + (List.length to_commit) in
  ({state with 
    commit_no = commit_no;
    client_table = client_table;
    mach = mach;
   }, None)






  
