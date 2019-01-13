open Core
open ClientState
open ReplicaState
open VR_Events

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

let map_falses l f =
  let rec map_falses l f i acc = 
    match l with
    | [] -> acc
    | (b::bs) -> if b then map_falses bs f (i+1) acc else map_falses bs f (i+1) ((f i)::acc) in
  map_falses l f 0 []

let commit state commit_until = 
  let last_committed_index = (List.length state.log) - 1 - state.commit_no in
  let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
  let (mach, client_table, replies) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
  let commit_no = state.commit_no + (List.length to_commit) in
  (commit_no, mach, client_table, replies)

let rec compare_logs log1 log2 = 
  match log1 with
  | [] -> Some(log2)
  | r1::log1 ->
    match log2 with
    | [] -> Some(r1::log1)
    | r2::log2 ->
      if r1 = r2 then
        compare_logs log1 log2
      else
        None
