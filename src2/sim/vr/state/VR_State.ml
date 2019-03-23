open Core

module StateMachine = StateMachine.KeyValueStore

open ReplicaState.ReplicaState(StateMachine)
open ClientState.ClientState(StateMachine)

type index = int

type message = ReplicaMessage of replica_message | ClientMessage of client_message
type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list
type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int
type protocol_event = Communication of communication | Timeout of timeout

let received_clientrecoveryresponse state i = 
  let received_clientrecoveryresponse_opt = List.nth state.received_clientrecoveryresponses i in
  match received_clientrecoveryresponse_opt with
  | None -> (* no such replica exists *) assert(false)
  | Some(received_clientrecoveryresponse) -> received_clientrecoveryresponse

let log_clientrecoveryresponse state v s i =
  let view_no = max state.view_no v in
  let request_no = max state.request_no s in
  let no_clientrecoveryresponses = state.no_clientrecoveryresponses + 1 in
  let received_clientrecoveryresponses = List.mapi state.received_clientrecoveryresponses (fun idx b -> if idx = i then true else b) in
  {state with 
   view_no = view_no;
   request_no = request_no;
   no_clientrecoveryresponses = no_clientrecoveryresponses;
   received_clientrecoveryresponses = received_clientrecoveryresponses;
  }

let client_set_recovering state r = 
  let valid_timeout = state.valid_timeout + 1 in
  if r then
    {state with 
     recovering = true; 
     valid_timeout = valid_timeout;
    }
  else
    let request_no = state.request_no + 1 in
    let received_clientrecoveryresponses = List.map state.received_clientrecoveryresponses (fun _ -> false) in
    {state with 
     request_no = request_no;
     recovering = false;
     no_clientrecoveryresponses = 0;
     received_clientrecoveryresponses = received_clientrecoveryresponses;
     valid_timeout = valid_timeout;
    }

let next_operation state = 
  let op_opt = List.nth state.operations_to_do state.next_op_index in
  let next_op_index = state.next_op_index + 1 in
  let request_no = state.request_no + 1 in
  let valid_timeout = valid_timeout + 1 in
  ({state with 
    request_no = request_no;
    next_op_index = next_op_index;
    valid_timeout = valid_timeout;
   }, op_opt)

let client_set_view_no state v = {state with view_no = v; }

let client_primary_no state = state.view_no mod (List.length state.configuration)

let client_id state = state.client_id

let client_request_no state = state.request_no

let client_valid_timeout state = state.valid_timeout

let client_recovering state = state.recovering

let client_quorum state = ((List.length state.configuration) / 2) + 1

let client_no_received_clientrecoveryresponses state = state.no_clientrecoveryresponses





let is_primary state = state.view_no mod (List.length state.configuration) = state.replica_no

let primary_no state = state.view_no mod (List.length state.configuration)

let view_no state = state.view_no

let replica_no state = state.replica_no

let op_no state = state.op_no

let commit_no state = state.commit_no

let status state = state.status

let log state = state.log

let quorum state = ((List.length state.configuration) / 2) + 1

let max_failures state = ((List.length state.configuration) / 2)

let increment_view_no state = 
  let view_no = state.view_no + 1 in
  let no_startviewchanges = 0 in
  let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
  {state with 
   view_no = view_no; 
   no_startviewchanges = no_startviewchanges;
   received_startviewchanges = received_startviewchanges;
  }

let set_status state status = 
  let valid_timeout = state.valid_timeout + 1 in
  let recovery_nonce = 
    if status = Recovery then
      state.recovery_nonce + 1 
    else
      state.recovery_nonce in
  let last_normal_view_no = 
    if status = Normal then
      state.view_no
    else
      state.last_normal_view_no in
  {state with 
   status = status; 
   last_normal_view_no = last_normal_view_no;
   recovery_nonce = recovery_nonce;
   valid_timeout = valid_timeout;
  }

let get_client_table_entry state c = 
  let cte_opt = List.nth state.client_table c in
  match cte_opt with 
  | None -> (* no client table entry for this client id *) assert(false)
  | Some(s, res_opt) -> (s, res_opt)

let rollback_to_commit state = 
  let op_no = state.commit_no in
  let remove_until = state.op_no - state.commit_no in
  let log = List.drop state.log remove_until in
  let valid_timeout = state.valid_timeout + 1 in
  {state with 
   view_no = v;
   op_no = op_no;
   log = log;
   valid_timeout = valid_timeout;
  }

let log_suffix state n' = 
  let take_until = state.op_no - n' in
  List.take state.log take_until

let append_log state l n =
  let l = List.take l (n - state.op_no) in
  let log = List.append l state.log in
  {state with 
   log = log;
   queued_prepares = [];
  }

let last_normal_view_no = state.last_normal_view_no

let valid_timeout state = state.valid_timeout

let no_primary_comms state = state.no_primary_comms

let no_received_startviewchanges state = state.no_startviewchanges

let no_received_doviewchanges state = state.no_doviewchanges

let current_recovery_nonce state = state.recovery_nonce

let no_received_recoveryresponses state = state.no_recoveryresponses

let primary_recoveryresponse state = state.primary_recoveryresponse

let get_casted_prepareok state i =
  let casted_prepareok_opt = List.nth state.casted_prepareoks i in
  match casted_prepareok_opt with
  | None -> (* no such replica *) assert(false)
  | Some(casted_prepareok) -> casted_prepareok

let received_startviewchange state i = 
  let received_startviewchange_opt = List.nth state.received_startviewchanges i in
  match received_startviewchange_opt with
  | None -> (* no replica for this index *) assert(false)
  | Some(received_startviewchange) -> received_startviewchange

let log_startviewchange state i =
  let no_startviewchanges = state.no_startviewchanges + 1 in
  let received_startviewchanges = List.mapi state.received_startviewchanges (fun idx b -> if idx = i then true else b) in
  {state with 
   no_startviewchanges = no_startviewchanges;
   received_startviewchanges = received_startviewchanges;
  }

let received_doviewchange state i =
  let rec received_doviewchange doviewchanges = 
    match doviewchanges with
    | [] -> false
    | (_, _, _, _, _, j)::doviewchanges -> if i = j then true else received_doviewchange doviewchanges in
  received_doviewchange state.doviewchanges

let log_doviewchange state v l v' n k i = 
  let no_doviewchanges = (List.length state.doviewchanges) + 1 in
  let doviewchanges = (v, l, v', n, k, i)::state.doviewchanges in
  {state with 
   no_doviewchanges = no_doviewchanges;
   doviewchanges = doviewchanges;
  }

let received_recoveryresponse state j = 
  let received_recoveryresponse_opt = List.nth state.received_recoveryresponses j in
  match received_recoveryresponse_opt with
  | None -> (* no such replica *) assert(false)
  | Some(received_recoveryresponse) -> received_recoveryresponse

let log_recoveryresponse state v x opt_p j =
  let view_no = max v state.view_no in
  let no_recoveryresponses = state.no_recoveryresponses + 1 in
  let received_recoveryresponses = List.mapi state.received_recoveryresponses (fun i b -> if i = j then true else b) in
  let primary_recoveryresponse = 
    match opt_p with
    | Some(l, n, k) -> if v < state.view_no then state.primary_recoveryresponse else Some(v, x, l, n, k, j)
    | None -> if v > state.view_no then None else state.primary_recoveryresponse in
  {state with 
   view_no = view_no;
   no_recoveryresponses = no_recoveryresponses;
   received_recoveryresponses = received_recoveryresponses;
   primary_recoveryresponse = primary_recoveryresponse;
  }

let process_doviewchanges state = 
  let rec process_doviewchanges doviewchanges view_no log last_normal_view_no op_no commit_no = 
    match doviewchanges with 
    | [] -> (view_no, log, op_no, commit_no)
    | (v, l, v', n, k, i)::doviewchanges -> 
      let view_no = if (v > view_no) then v else view_no
      let (log, last_normal_view_no, op_no) = 
        if (v' > last_normal_view_no || (v' = last_normal_view_no && n > op_no)) then 
          (l, v', n)
        else
          (view_no, log, last_normal_view_no, op_no) in
      let commit_no = if (k > commit_no) then k else commit_no in
      process_doviewchanges doviewchanges view_no log last_normal_view_no op_no commit_no in
  let (view_no, log, op_no, commit_no) = process_doviewchanges doviewchanges -1 [] -1 -1 -1 in
  ({state with 
    view_no = view_no;
    op_no = op_no;
    log = log;
    highest_seen_commit_no = commit_no;
   }, commit_no)

let become_primary state = 
  let waiting_prepareoks = List.init (state.op_no - state.highest_seen_commit_no) (fun _ -> 0) in
  let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
  let casted_prepareoks = List.map state.casted_prepareoks (fun _ -> state.highest_seen_commit_no) in
  let valid_timeout = state.valid_timeout + 1 in
  ({state with 
    queued_prepares = [];
    waiting_prepareoks = waiting_prepareoks;
    casted_prepareoks = casted_prepareoks;
    no_startviewchanges = 0;
    received_startviewchanges = received_startviewchanges;
    doviewchanges = [];
    valid_timeout = valid_timeout;
    no_primary_comms = 0;
   })

let set_view_no state v = {state with view_no = v; }
let set_op_no state n = {state with op_no = n; }
let set_log state l = {state with log = l; }

let become_replica state = 
  let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
  let received_recoveryresponses = List.map state.received_recoveryresponses (fun _ -> false) in
  let valid_timeout = state.valid_timeout + 1 in
  {state with 
   queued_prepares = [];
   waiting_prepareoks = [];
   no_startviewchanges = 0;
   received_startviewchanges = received_startviewchanges;
   doviewchanges = [];
   no_recoveryresponses = 0;
   received_recoveryresponses = received_recoveryresponses;
   primary_recoveryresponse = None;
   valid_timeout = valid_timeout;
   no_primary_comms = 0;
  }

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
