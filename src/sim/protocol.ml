open Core

module StateMachine = StateMachine.KeyValueStore

type client_message =
  | Reply of int * int * StateMachine.result
  | ClientRecoveryResponse of int * int * int
  
type replica_message =
  | Request of StateMachine.operation * int * int
  | Prepare of int * (StateMachine.operation * int * int) * int * int
  | PrepareOk of int * int * int
  | Commit of int * int
  | StartViewChange of int * int
  | DoViewChange of int * (StateMachine.operation * int * int) list * int * int * int * int
  | StartView of int * (StateMachine.operation * int * int) list * int * int
  | Recovery of int * int
  | RecoveryResponse of int * int * ((StateMachine.operation * int * int) list * int * int) option * int
  | ClientRecovery of int
  | GetState of int * int * int
  | NewState of int * (StateMachine.operation * int * int) list * int * int

type message = ReplicaMessage of replica_message | ClientMessage of client_message

type communication = Unicast of message * int |  Broadcast of message | MultiComm of communication list

type status =
  | Normal
  | ViewChange
  | Recovering

type client_state = {
  configuration : int list;
  view_no : int;
  client_id : int;
  request_no : int;

  next_op_index : int; (* index of next operation to be sent in request*)
  operations_to_do : StateMachine.operation list; (* list of operations client wants to perform *)
  
  recovering : bool; (* indicates if the client is recovering from a crash or not *)
  no_clientrecoveryresponses : int; (* the number of clientrecoverresponses received for current recovery *)
  received_clientrecoveryresponses : bool list; (* for each replica indicates whether they have responded to recovery or not *)
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

  queued_prepares : (StateMachine.operation * int * int) option list; (* list of operations depending on previous operations not yet seen *)
  waiting_prepareoks : int list; (* for each not yet committed operation, the number of prepareoks received *)
  casted_prepareoks : int list; (* for each replica, the highest op_no seen in a prepareok message *)
  highest_seen_commit_no : int; (* the higest commit_no seen in a prepare/commit message *)

  no_startviewchanges : int; (* number of startviewchange messages received from different replicas *)
  received_startviewchanges : bool list; (* for each replica, indicates whether this has received a startviewchange from them *)
  doviewchanges : (int * (StateMachine.operation * int * int) list * int * int * int * int) list; (* list of doviewchange messages received *)
  last_normal_view_no : int; (* view_no of the last view for which status was normal *)

  recovery_nonce : int; (* the nonce used in this replica's most recent recovery *)
  no_recoveryresponses : int; (* number of recoveryresponse messages received from different replicas *)
  received_recoveryresponses : bool list; (* for each replica, indicates whether this has received a recoveryresponse from them *)
  primary_recoveryresponse : (int * int * (StateMachine.operation * int * int) list * int * int * int) option; (* recoveryresponse message from primary of latest view seen in recoveryresponse messages *)

  mach: StateMachine.t;
}

  (* normal operation protocol implementation *)

    (* HELPER FUNCTIONS BEGIN *)

let is_primary state = 
  state.view_no mod (List.length state.configuration) = state.replica_no

let primary_no v conf = 
  v mod (List.length conf)

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
      commit_all mach ct reqs (Unicast(ClientMessage(Reply(view_no, s, res)), c)::replies)
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
        | Some(res) -> (* return result for most recent operation *) (state, Some(Unicast(ClientMessage(Reply(state.view_no, s, res)), c)))
      else if (cte_s > s) then
        (* begin protocol to execute new request *)
        let op_no = state.op_no + 1 in
        let log = (op, c, s)::state.log in
        let client_table = update_ct state.client_table c s in
        let waiting_prepareoks = 0::state.waiting_prepareoks in
        ({state with 
          op_no = op_no;
          log = log;
          client_table = client_table;
          waiting_prepareoks = waiting_prepareoks;
         }, Some(Broadcast(ReplicaMessage(Prepare(state.view_no, (op, c, s), op_no, state.commit_no)))))
      else
        (* drop request *) (state, None)
  else
    (state, None)

let on_prepare state v (op, c, s) n k = 
  let primary_no = primary_no state.view_no state.configuration in
  if state.op_no >= n then
    (* already prepared request so re-send prepareok *)
    (state, Some(Unicast(ReplicaMessage(PrepareOk(state.view_no, state.op_no, state.replica_no)), primary_no)))
  else
    (* try to prepare request, may not be able to without earlier requests, and send prepareok if prepared anything *)
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
    let comm_opt = 
      if op_no > state.op_no then Some(Unicast(ReplicaMessage(PrepareOk(state.view_no, op_no, state.replica_no)), primary_no)) else None in
    ({state with 
      op_no = op_no;
      log = log;
      client_table = client_table;
      queued_prepares = queued_prepares;
     }, comm_opt)

let on_prepareok state v n i = 
  let casted_prepareok_opt = List.nth state.casted_prepareoks i in
  match casted_prepareok_opt with
  | None -> (* no such replica *) assert(false)
  | Some(casted_prepareok) ->
    if casted_prepareok >= n || state.commit_no >= n then
      (* either already received a prepareok from this replica or already committed operation *)
      (state, None)
    else
      let f = ((List.length state.configuration) / 2) in
      let no_waiting = List.length state.waiting_prepareoks in
      let index = state.commit_no + no_waiting - n in
      let last_casted_index = state.commit_no + no_waiting - casted_prepareok in
      let waiting_prepareoks = List.mapi state.waiting_prepareoks (fun i w -> if i >= index && i < last_casted_index then w+1 else w) in
      let (waiting_prepareoks, commit_until) = process_waiting_prepareoks f waiting_prepareoks in 
      let last_committed_index = (List.length state.log) - 1 - state.commit_no in
      let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
      let (mach, client_table, replies) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
      let commit_no = state.commit_no + (List.length to_commit) in
      let comm_opt = if List.length replies > 0 then Some(MultiComm(replies)) else None in
      let casted_prepareoks = List.mapi state.casted_prepareoks (fun idx m -> if idx = i then n else m) in
      ({state with 
        commit_no = commit_no;
        client_table = client_table;
        waiting_prepareoks = waiting_prepareoks;
        casted_prepareoks = casted_prepareoks;
        mach = mach;
       }, comm_opt)

let on_commit state v k = 
  let k = max state.highest_seen_commit_no k in
  let commit_until = (List.length state.log) - 1 - k in
  let last_committed_index = (List.length state.log) - 1 - state.commit_no in
  let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
  let (mach, client_table, _) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
  let commit_no = state.commit_no + (List.length to_commit) in
  ({state with 
    commit_no = commit_no;
    client_table = client_table;
    highest_seen_commit_no = k;
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

let rec received_doviewchange doviewchanges i = 
  match doviewchanges with
  | [] -> false
  | (_, _, _, _, _, j)::doviewchanges -> if i = j then true else received_doviewchange doviewchanges i

    (* HELPER FUNCTIONS END *)

let notice_viewchange state = 
  let view_no = state.view_no + 1 in 
  let status = ViewChange in
  let no_startviewchanges = 0 in
  let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
  ({state with 
    view_no = view_no;
    status = status;
    no_startviewchanges = no_startviewchanges;
    received_startviewchanges = received_startviewchanges;
   }, Some(Broadcast(ReplicaMessage(StartViewChange(view_no, state.replica_no)))))

let on_startviewchange state v i =
  let received_startviewchange_opt = List.nth state.received_startviewchanges i in
  match received_startviewchange_opt with
  | None -> (* no replica for this index *) assert(false)
  | Some(received_startviewchange) ->
    if received_startviewchange then
      (* already received a startviewchange from this replica*)
      (state, None)
    else
      let f = ((List.length state.configuration) / 2) in
      let no_startviewchanges = state.no_startviewchanges + 1 in
      let primary_no = primary_no state.view_no state.configuration in
      let comm_opt = 
        if (no_startviewchanges = f) then 
          Some(Unicast(ReplicaMessage(DoViewChange(state.view_no, state.log, state.last_normal_view_no, state.op_no, state.commit_no, state.replica_no)), primary_no))
        else
          None in
      let received_startviewchanges = List.mapi state.received_startviewchanges (fun idx b -> if idx = i then true else b) in
      ({state with 
        no_startviewchanges = no_startviewchanges;
        received_startviewchanges = received_startviewchanges;
       }, comm_opt)

let on_doviewchange state v l v' n k i = 
  let received_doviewchange = received_doviewchange state.doviewchanges i in
  if received_doviewchange then
    (* already received a doviewchange message from this replica *)
    (state, None)
  else  
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
      let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
      let casted_prepareoks = List.map state.casted_prepareoks (fun _ -> commit_no) in
      ({state with 
        view_no = view_no;
        status = status;
        op_no = op_no;
        log = log;
        commit_no = commit_no;
        client_table = client_table;
        queued_prepares = [];
        waiting_prepareoks = waiting_prepareoks;
        casted_prepareoks = casted_prepareoks;
        highest_seen_commit_no = commit_no;
        no_startviewchanges = 0;
        received_startviewchanges = received_startviewchanges;
        doviewchanges = [];
        last_normal_view_no = view_no;
        mach = mach;
       }, Some(MultiComm(Broadcast(ReplicaMessage(StartView(view_no, log, op_no, commit_no)))::replies)))
    else 
      ({state with 
        doviewchanges = doviewchanges;
       }, None)

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
  let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
  let primary_no = primary_no view_no state.configuration in
  let comm_opt = 
    if (commit_no < op_no) then
      Some(Unicast(ReplicaMessage(PrepareOk(view_no, op_no, state.replica_no)), primary_no))
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
    highest_seen_commit_no = commit_no;
    no_startviewchanges = 0;
    received_startviewchanges = received_startviewchanges;
    doviewchanges = [];
    last_normal_view_no = view_no;
    mach = mach;
   }, comm_opt)

  (* recovery protocol implementation *)

let begin_recovery state = 
  let status = Recovering in
  let i = state.replica_no in
  let x = state.recovery_nonce + 1 in
  ({state with 
    status = status;
    recovery_nonce = x;
   }, Some(Broadcast(ReplicaMessage(Recovery(i, x)))))

let on_recovery state i x =
  let v = state.view_no in
  let j = state.replica_no in
  if is_primary state then
    let l = state.log in
    let n = state.op_no in
    let k = state.commit_no in
    (state, Some(Unicast(ReplicaMessage(RecoveryResponse(v, x, Some(l, n, k), j)), i)))
  else
    (state, Some(Unicast(ReplicaMessage(RecoveryResponse(v, x, None, j)), i)))

let on_recoveryresponse state v x opt_p j = 
  if state.recovery_nonce <> x then
    (state, None)
  else
    let received_recoveryresponse_opt = List.nth state.received_recoveryresponses j in
    match received_recoveryresponse_opt with
    | None -> (* no such replica *) assert(false)
    | Some(received_recoveryresponse) ->
      if received_recoveryresponse then
        (* already received a recovery response from this replica *)
        (state, None)
      else
        let no_recoveryresponses = state.no_recoveryresponses + 1 in
        let received_recoveryresponses = List.mapi state.received_recoveryresponses (fun i b -> if i = j then true else b) in
        let primary_recoveryresponse = 
          match opt_p with
          | Some(l, n, k) -> if v < state.view_no then state.primary_recoveryresponse else Some(v, x, l, n, k, j)
          | None -> if v > state.view_no then None else state.primary_recoveryresponse in
        let view_no = max v state.view_no in
        let f = ((List.length state.configuration) / 2) in
        if no_recoveryresponses >= f+1 then
          match state.primary_recoveryresponse with
          | Some(v, x, l, n, k, j) ->
            let log = l in
            let op_no = n in
            let status = Normal in 
            let commit_no = k in
            let last_committed_index = (List.length state.log) - 1 - state.commit_no in
            let commit_until = (List.length state.log) - 1 - commit_no in
            let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
            let (mach, client_table, _) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
            let received_recoveryresponses = List.map state.received_recoveryresponses (fun _ -> false) in
            ({state with 
              view_no = view_no;
              log = log;
              op_no = op_no;
              status = status;
              commit_no = k;
              client_table = client_table;
              no_recoveryresponses = 0;
              received_recoveryresponses = received_recoveryresponses;
              primary_recoveryresponse = None;
              mach = mach;
             }, None)
          | None -> ({state with 
                      view_no = view_no;
                      no_recoveryresponses = no_recoveryresponses;
                      received_recoveryresponses = received_recoveryresponses;
                      primary_recoveryresponse = primary_recoveryresponse;
                     }, None)
        else
          ({state with 
            view_no = view_no;
            no_recoveryresponses = no_recoveryresponses;
            received_recoveryresponses = received_recoveryresponses;
            primary_recoveryresponse = primary_recoveryresponse;
           }, None)
    
  (* client recovery protocol implementation *)
    
let begin_clientrecovery state = 
  ({state with 
    recovering = true;
   }, Some(Broadcast(ReplicaMessage(ClientRecovery(state.client_id)))))

let on_clientrecovery state c = 
  let v = state.view_no in
  let i = state.replica_no in
  let opt = List.nth state.client_table c in
  match opt with 
  | None -> assert(false)
  | Some(s, res) ->
    (state, Some(Unicast(ClientMessage(ClientRecoveryResponse(v, s, i)), c)))

let on_clientrecoveryresponse (state : client_state) v s i = 
  if not state.recovering then
    (* client is not recovering *)
    (state, None)
  else
    let received_clientrecoveryresponse_opt = List.nth state.received_clientrecoveryresponses i in
    match received_clientrecoveryresponse_opt with
    | None -> (* no such replica exists *) assert(false)
    | Some(received_clientrecoveryresponse) -> 
      if received_clientrecoveryresponse then
        (* already received a clientrecoveryresponse from this replica *)
        (state, None)
      else
        let f = ((List.length state.configuration) / 2) in
        let no_clientrecoveryresponses = state.no_clientrecoveryresponses + 1 in
        let request_no = max s state.request_no in
        let view_no = max v state.view_no in
        if no_clientrecoveryresponses = f+1 then
          let received_clientrecoveryresponses = List.map state.received_clientrecoveryresponses (fun _ -> false) in
          ({state with 
            view_no = view_no;
            request_no = request_no + 2;
            recovering = false;
            no_clientrecoveryresponses = 0;
            received_clientrecoveryresponses = received_clientrecoveryresponses;
           }, None)
        else
          let received_clientrecoveryresponses = List.mapi state.received_clientrecoveryresponses (fun idx b -> if idx = i then true else b) in
          ({state with 
            view_no = view_no;
            request_no = request_no;
            no_clientrecoveryresponses = no_clientrecoveryresponses;
            received_clientrecoveryresponses = received_clientrecoveryresponses;
           }, None)
      
  (* state transfer protocol implementation *)

let begin_statetransfer state = 
  let primary_no = primary_no state.view_no state.configuration in
  (state, Some(Unicast(ReplicaMessage(GetState(state.view_no, state.op_no, state.replica_no)), primary_no)))

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
  (state, Some(Unicast(ReplicaMessage(NewState(state.view_no, log, state.op_no, state.commit_no)), i)))

let on_newstate state v l n k =
  if n <= state.op_no then
    (* replica has already got this state *)
    (state, None)
  else
    let log = List.append l state.log in
    let commit_until = (List.length log) - 1 - k in
    let last_committed_index = (List.length log) - 1 - state.commit_no in
    let to_commit = List.filteri log (fun i _ -> i < last_committed_index && i >= commit_until) in
    let (mach, client_table, _) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
    ({state with 
      op_no = n;
      log = log;
      commit_no = k;
      client_table = client_table;
      queued_prepares = [];
      waiting_prepareoks = [];
      mach = mach;
     }, None)

  (* client-side normal protocol implementation *)

let on_reply state v s res = 
  if s < state.request_no || state.recovering then
    (* already received this reply or recovering so cant proceed *)
    (state, None)
  else
    let request_no = s + 1 in
    let op_opt = List.nth state.operations_to_do state.next_op_index in
    let next_op_index = state.next_op_index + 1 in
    let primary_no = primary_no v state.configuration in
    let state = {state with 
                 request_no = request_no;
                 view_no = v;
                 next_op_index = next_op_index;
                } in
    match op_opt with
    | None -> (state, None)
    | Some(op) -> (state, Some(Unicast(ReplicaMessage(Request(op, state.client_id, request_no)), primary_no)))

    (* tying protocol implementation together *)

(* perform status and view number checks here *)
let on_replica_message state msg = 
  match msg with
  | Request(op, c, s) ->
    on_request state op c s
  | Prepare(v, m, n, k) -> 
    if state.status <> Normal || v < state.view_no then
      (state, None)
    else if v > state.view_no then
      later_view state v
    else
      let (state, comm_opt) = on_prepare state v m n k in
      let (state, _) = on_commit state v k in
      (state, comm_opt)
  | PrepareOk(v, n, i) -> 
    if state.status <> Normal || v < state.view_no then
      (state, None)
    else if v > state.view_no then
      later_view state v
    else
      on_prepareok state v n i 
  | Commit(v, k) -> 
    if state.status <> Normal || v < state.view_no then
      (state, None)
    else if v > state.view_no then
      later_view state v
    else
      on_commit state v k
  | StartViewChange(v, i) -> 
    if state.status = Recovering || v < state.view_no then
      (state, None)
    else if v > state.view_no then
      notice_viewchange state
    else
      on_startviewchange state v i
  | DoViewChange(v, l, v', n, k, i) -> 
    if state.status = Recovering || v < state.view_no then
      (state, None)
    else if v > state.view_no then
      notice_viewchange state
    else
      on_doviewchange state v l v' n k i
  | StartView(v, l, n, k) -> 
    if state.status = Recovering || v < state.view_no then
      (state, None)
    else
      on_startview state v l n k
  | Recovery(i, x) -> 
    if state.status <> Normal then
      (state, None)
    else
      on_recovery state i x
  | RecoveryResponse(v, x, opt, j) -> 
    if state.status <> Recovering then
      (state, None)
    else
      on_recoveryresponse state v x opt j
  | ClientRecovery(c) -> 
    on_clientrecovery state c
  | GetState(v, n', i) -> 
    if state.status <> Normal || state.view_no <> v then
      (state, None)
    else
      on_getstate state v n' i
  | NewState(v, l, n, k) -> 
    if state.status <> Normal || state.view_no <> v then
      (state, None)
    else
      on_newstate state v l n k

let on_client_message state msg =
  match msg with 
  | Reply(v, s, res) -> 
    on_reply state v s res
  | ClientRecoveryResponse(v, s, i) -> 
    on_clientrecoveryresponse state v s i

  (* implementing state initialization/crash *)



















