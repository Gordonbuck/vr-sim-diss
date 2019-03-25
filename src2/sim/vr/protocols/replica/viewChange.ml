open Core
open VR_State

let notice_viewchange state = 
  let state = set_status state ViewChange in
  let state = increment_view_no state in
  (state, [Communication(Broadcast(ReplicaMessage(StartViewChange(view_no state, replica_no state))));
           Timeout(ReplicaTimeout(StartViewChangeTimeout(valid_timeout state), replica_no state))])

let on_startviewchange state v i =
  if v > (view_no state) && (status state) <> Recovering then
    notice_viewchange state
  else if v = (view_no state) && (status state) = ViewChange then
    let received_startviewchange = received_startviewchange state i in
    if received_startviewchange then
      (* already received a startviewchange from this replica*)
      (state, [])
    else
      let state = log_startviewchange state i in
      let f = (quorum state) - 1 in
      let primary_no = primary_no state in
      let no_startviewchanges = no_received_startviewchanges state in
      let events = 
        if (no_startviewchanges = f) then
          let msg = DoViewChange(view_no state, log state, last_normal_view_no state, op_no state, 
                                 commit_no state, replica_no state) in
          let comm = Unicast(ReplicaMessage(msg), primary_no) in
          [Communication(comm); 
           Timeout(ReplicaTimeout(DoViewChangeTimeout(valid_timeout state), replica_no state));
           Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), replica_no state))]
        else [] in
      (state, events)
  else
    (state, [])

let on_doviewchange state v l v' n k i =
  if (status state) = Recovering || v < (view_no state) then
    (state, [])
  else if v > (view_no state) then
    notice_viewchange state
  else if (status state) = Normal then
    (* recovered, re-send startview message *)
    (state, [Communication(Unicast(ReplicaMessage(StartView(view_no state, log state, op_no state, commit_no state)), i))])
  else
    let received_doviewchange = received_doviewchange state i in
    if received_doviewchange then
      (* already received a doviewchange message from this replica *)
      (state, [])
    else  
      let state = log_doviewchange state v l v' n k i in
      let no_doviewchanges = no_received_doviewchanges state in
      let q = quorum state in
      if (no_doviewchanges = q) then
        let (state, k) = process_doviewchanges state in
        let state = set_status state Normal in
        let state = become_primary state in
        let (state, replies) = commit state k in
        let events = List.map replies (fun c -> Communication(c)) in
        let timeout = ReplicaTimeout(HeartbeatTimeout(replica_no state, op_no state), replica_no state) in
        let comm = Broadcast(ReplicaMessage(StartView(view_no state, log state, op_no state, commit_no state))) in
        (state, Timeout(timeout)::Communication(comm)::events)
      else
        (state, [])

let on_startview state v l n k = 
  if (status state) = Recovering || v < (view_no state) || (v = (view_no state) && (status state) <> ViewChange) then
    (state, [])
  else
    let state = set_view_no state v in
    let state = set_op_no state n in
    let state = set_log state l in
    let state = become_replica state in
    let (state, _) = commit state k in
    let events = 
      if ((commit_no state) < (op_no state)) then
        [Communication(Unicast(ReplicaMessage(PrepareOk(view_no state, op_no state, replica_no state)), primary_no state))]
      else
        [] in
    (state, Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), replica_no state))::events)


