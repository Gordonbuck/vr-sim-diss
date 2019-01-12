open Core
open ClientState
open ReplicaState
open ProtocolEvents
open VR_Utils

let begin_statetransfer state = 
  let primary_no = primary_no state.view_no state.configuration in
  (state, [Communication(Unicast(ReplicaMessage(GetState(state.view_no, state.op_no, state.replica_no)), primary_no));
           Timeout(ReplicaTimeout(GetStateTimeout(state.valid_timeout, state.op_no), state.replica_no))])

let later_view state v = 
  let op_no = state.commit_no in
  let remove_until = state.op_no - state.commit_no in
  let log = List.drop state.log remove_until in
  let valid_timeout = state.valid_timeout + 1 in
  begin_statetransfer {state with 
                       view_no = v;
                       op_no = op_no;
                       log = log;
                       valid_timeout = valid_timeout;
                      }

let on_getstate state v n' i = 
  if state.status <> Normal || state.view_no <> v then
    (state, [])
  else
    let take_until = state.op_no - n' in
    let log = List.take state.log take_until in
    (state, [Communication(Unicast(ReplicaMessage(NewState(state.view_no, log, state.op_no, state.commit_no)), i))])

let on_newstate state v l n k =
  if n <= state.op_no || state.status <> Normal || state.view_no <> v then
    (state, [])
  else
    let log = List.append l state.log in
    let (commit_no, mach, client_table, replies) = commit state ((List.length state.log) - 1 - k) in
    let no_primary_comms = state.no_primary_comms + 1 in
    ({state with 
      op_no = n;
      log = log;
      commit_no = k;
      client_table = client_table;
      queued_prepares = [];
      waiting_prepareoks = [];
      mach = mach;
      no_primary_comms = no_primary_comms;
     }, [Timeout(ReplicaTimeout(PrimaryTimeout(state.valid_timeout, no_primary_comms), state.replica_no))])
