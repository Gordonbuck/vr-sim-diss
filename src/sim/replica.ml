open Core

module StateMachine = StateMachine.KeyValueStore

type client_message =
  | Request of StateMachine.operation * int * int
  | ClientRecovery of int

type replica_message =
  | Prepare of int * client_message * int * int
  | PrepareOk of int * int * int
  | Reply of int * int * StateMachine.result
  | Commit of int * int
  | StartViewChange of int * int
  | DoViewChange of int * (StateMachine.operation * int * int) list * int * int * int * int
  | StartView of int * (StateMachine.operation * int * int) list * int * int
  | Recovery of int * int
  | RecoveryResponse of int * int * ((StateMachine.operation * int * int) list * int * int) option * int
  | ClientRecoveryResponse of int * int
  | GetState of int * int * int
  | NewState of int * (StateMachine.operation * int * int) list * int * int

type status =
  | Normal
  | ViewChange
  | Recovering

type client_state = {
  configuration : int list;
  view_no : int;
  client_id : int;
  request_no : int;

  recovering : bool;
  no_clientrecoveryresponses : int;
}

type replica_state = {
  configuration : int list;
  replica_no : int;
  view_no : int;
  status: status;
  op_no : int;
  log: (StateMachine.operation * int * int) list;
  commit_no : int;
  client_table: (int * StateMachine.result option) list;

  queued_prepares : (StateMachine.operation * int * int) option list;
  waiting_prepareoks : int list;

  no_startviewchanges : int;
  doviewchanges : (int * (StateMachine.operation * int * int) list * int * int * int * int) list;
  last_normal_view_no : int;

  recovery_nonce : int;
  no_recoveryresponses : int;
  latest_recovery_view : int;
  primary_recoveryresponse : (int * int * (StateMachine.operation * int * int) list * int * int * int) option;

  mach: StateMachine.t;
}

  (* normal operation protocol implementation *)

    (* HELPER FUNCTIONS BEGIN *)

let is_primary state = 
  state.view_no mod (List.length state.configuration) = state.replica_no

let update_ct ?(res=None) ct c s = List.mapi ct (fun i cte -> if i = c then (s, res) else cte)

let rec update_ct_reqs ct reqs = 
  match reqs with
  | (op, c, s)::reqs -> update_ct_reqs (update_ct ct c s) reqs
  | [] -> ct

let rec add_nones l n = 
  match n with 
  | _ when n < 1 -> l
  | n -> add_nones (None::l) (n - 1)

let process_queued_prepares queued_prepares =
  let rec process_queued_prepares rev_queued_prepares prepared =
    match rev_queued_prepares with
    | (None::_) | [] -> (rev_queued_prepares, prepared)
    | (Some(req)::rev_queued_prepares) -> process_queued_prepares rev_queued_prepares (req::prepared) in
  let (rev_queued_prepares, prepared) = process_queued_prepares (List.rev queued_prepares) [] in
  (List.rev rev_queued_prepares, prepared)

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
    | (op, c, s)::reqs -> 
      let mach = StateMachine.apply_op mach op in
      let res = StateMachine.last_res mach in
      let ct = update_ct ct c s ~res:(Some(res)) in
      commit_all mach ct reqs (Reply(view_no, s, res)::replies)
    | _ -> (mach, ct, replies) in
  commit_all mach ct reqs []

    (* HELPER FUNCTIONS END *)

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
        let log = (op, c, s)::state.log in
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

let on_prepare state v (op, c, s) n k = 
  (* on_prepare assumes request being sent isnt already in log *)
  let no_queued = List.length state.queued_prepares in
  let index = state.op_no + no_queued - n in
  let queued_prepares = 
    if (index >= 0) then 
      List.mapi state.queued_prepares (fun i req_opt -> if i = index then Some((op, c, s)) else req_opt)
    else 
      Some((op, c, s))::(add_nones state.queued_prepares (-(index + 1))) in    
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
     }, replies)

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

  (* view change protocol implementation *)

    (* HELPER FUNCTIONS BEGIN *)

let process_doviewchanges doviewchanges =
  let rec process_doviewchanges doviewchanges log last_normal_view_no op_no commit_no = 
    match doviewchanges with 
    | [] -> (log, last_normal_view_no, op_no, commit_no)
    | (v, l, v', n, k, i)::doviewchanges -> 
      let (log, last_normal_view_no, op_no) = 
        if (v' > last_normal_view_no || (v' = last_normal_view_no && n > op_no)) then 
          (l, v', n)
        else
          (log, last_normal_view_no, op_no) in
      let commit_no = if (k > commit_no) then k else commit_no in
      process_doviewchanges doviewchanges log last_normal_view_no op_no commit_no in
  process_doviewchanges doviewchanges [] 0 0 0

    (* HELPER FUNCTIONS END *)

let notice_viewchange state = 
  let view_no = state.view_no + 1 in 
  let status = ViewChange in
  let no_startviewchanges = 0 in
  ({state with 
    view_no = view_no;
    status = status;
    no_startviewchanges = no_startviewchanges;
   }, StartViewChange(view_no, state.replica_no))

let on_startviewchange state v i =
  let f = ((List.length state.configuration) / 2) in
  let no_startviewchanges = state.no_startviewchanges + 1 in
  let message_opt = 
    if (no_startviewchanges = f) then 
      Some(DoViewChange(state.view_no, state.log, state.last_normal_view_no, state.op_no, state.commit_no, state.replica_no))
    else
      None in
  ({state with 
    no_startviewchanges = no_startviewchanges;
   }, message_opt)
      
let on_doviewchange state v l v' n k i = 
  let f = ((List.length state.configuration) / 2) in
  let no_doviewchanges = (List.length state.doviewchanges) + 1 in
  let doviewchanges = (v, l, v', n, k, i)::state.doviewchanges in
  if (no_doviewchanges = f + 1) then
    let status = Normal in 
    let view_no = v in
    let (log, last_normal_view_no, op_no, commit_no) = process_doviewchanges doviewchanges in
    let last_committed_index = (List.length state.log) - 1 - state.commit_no in
    let commit_until = (List.length state.log) - 1 - commit_no in
    let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
    let (mach, client_table, replies) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
    let waiting_prepareoks = List.init (op_no - commit_no) (fun _ -> 0) in
    ({state with 
      view_no = view_no;
      status = status;
      op_no = op_no;
      log = log;
      commit_no = commit_no;
      client_table = client_table;
      queued_prepares = [];
      waiting_prepareoks = waiting_prepareoks;
      no_startviewchanges = 0;
      doviewchanges = [];
      last_normal_view_no = view_no;
      mach = mach;
     }, (StartView(view_no, log, op_no, commit_no))::replies)
  else 
    ({state with 
      doviewchanges = doviewchanges;
     }, [])

let on_startview state v l n k = 
  let view_no = v in
  let log = l in
  let op_no = n in
  let status = Normal in 
  let commit_no = k in
  let last_committed_index = (List.length state.log) - 1 - state.commit_no in
  let commit_until = (List.length state.log) - 1 - commit_no in
  let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
  let (mach, client_table, _) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
  let message_opt = 
    if (commit_no < op_no) then
      Some(PrepareOk(view_no, op_no, state.replica_no))
    else
      None in
  ({state with 
    view_no = view_no;
    status = status;
    op_no = op_no;
    log = log;
    commit_no = commit_no;
    client_table = client_table;
    queued_prepares = [];
    waiting_prepareoks = [];
    no_startviewchanges = 0;
    doviewchanges = [];
    last_normal_view_no = view_no;
    mach = mach;
   }, message_opt)

  (* recovery protocol implementation *)

    (* HELPER FUNCTIONS BEGIN *)

    (* HELPER FUNCTIONS END *)

let begin_recovery state = 
  let status = Recovering in
  let i = state.replica_no in
  let x = 0 in
  ({state with 
    status = status;
   }, Recovery(i, x))

let on_recovery state i x =
  let v = state.view_no in
  let j = state.replica_no in
  if is_primary state then
    let l = state.log in
    let n = state.op_no in
    let k = state.commit_no in
    (state, RecoveryResponse(v, x, Some(l, n, k), j))
  else
    (state, RecoveryResponse(v, x, None, j))

let on_recoveryresponse state v x opt_p j = 
  if v < state.view_no || state.recovery_nonce <> x then
    state
  else 
    let state = 
      let primary_recoveryresponse = 
        match opt_p with
        | Some(l, n, k) -> Some(v, x, l, n, k, j)
        | None -> state.primary_recoveryresponse in
      if v > state.view_no then
        {state with 
         no_recoveryresponses = 1;
         latest_recovery_view = v;
         primary_recoveryresponse = primary_recoveryresponse;
        }
      else
        let no_recoveryresponses = state.no_recoveryresponses + 1 in
        {state with 
         no_recoveryresponses = no_recoveryresponses;
         primary_recoveryresponse = primary_recoveryresponse;
        } in
    let f = ((List.length state.configuration) / 2) in
    if state.no_recoveryresponses >= f+1 then
      match state.primary_recoveryresponse with
      | Some(v, x, l, n, k, j) ->
        let view_no = v in
        let log = l in
        let op_no = n in
        let status = Normal in 
        let commit_no = k in
        let last_committed_index = (List.length state.log) - 1 - state.commit_no in
        let commit_until = (List.length state.log) - 1 - commit_no in
        let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
        let (mach, client_table, _) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
        {state with 
         view_no = view_no;
         log = log;
         op_no = op_no;
         status = status;
         commit_no = k;
         client_table = client_table;
         no_recoveryresponses = 0;
         latest_recovery_view = view_no;
         primary_recoveryresponse = None;
         mach = mach;
        }
      | None -> state
    else
      state
    
  (* client recovery protocol implementation *)
    
let begin_clientrecovery state = 
  ({state with 
    recovering = true;
   }, ClientRecovery(state.client_id))

let on_clientrecovery state c = 
  let v = state.view_no in
  let opt = List.nth state.client_table c in
  match opt with 
  | None -> assert(false)
  | Some(s, res) ->
    (state, ClientRecoveryResponse(v, s))

let on_clientrecoveryresponse (state : client_state) v s = 
  if v < state.view_no then
    state
  else if v > state.view_no then
    {state with 
     view_no = v;
     request_no = s;
     no_clientrecoveryresponses = 1;
    }
  else
    let f = ((List.length state.configuration) / 2) in
    let no_clientrecoveryresponses = state.no_clientrecoveryresponses + 1 in
    let request_no = if s > state.request_no then s else state.request_no in
    if no_clientrecoveryresponses = f+1 then
      {state with 
       request_no = request_no;
       recovering = false;
       no_clientrecoveryresponses = 0;
      }
    else
      {state with 
       request_no = request_no;
       no_clientrecoveryresponses = no_clientrecoveryresponses;
      }
      
  (* state transfer protocol implementation *)

let begin_statetransfer state = 
  (state, GetState(state.view_no, state.op_no, state.replica_no))

let later_view state v = 
  let op_no = state.commit_no in
  let remove_until = state.op_no - state.commit_no in
  let log = List.drop state.log remove_until in
  begin_statetransfer {state with 
    view_no = v;
    op_no = op_no;
    log = log;
   }

let on_getstate state v n' i = 
  let take_until = state.op_no - n' in
  let log = List.take state.log take_until in
  (state, NewState(state.view_no, log, state.op_no, state.commit_no))

let on_newstate state v l n k =
  let log = List.append l state.log in
  let commit_until = (List.length log) - 1 - k in
  let last_committed_index = (List.length log) - 1 - state.commit_no in
  let to_commit = List.filteri log (fun i _ -> i < last_committed_index && i >= commit_until) in
  let (mach, client_table, _) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
  {state with 
   op_no = n;
   log = log;
   commit_no = k;
   client_table = client_table;
   queued_prepares = [];
   waiting_prepareoks = [];
   mach = mach;
  }














