open Core
open VR_State


let compare_logs log1 log2 = 
  let rec compare_logs rlog1 rlog2 = 
    match rlog1 with
    | [] -> Some(log2)
    | r1::rlog1 ->
      match rlog2 with
      | [] -> Some(log1)
      | r2::rlog2 ->
        if r1 = r2 then
          compare_logs rlog1 rlog2
        else
          None in
  compare_logs log1 log2

let check_consistency replicas = 
  let rec inner replicas log1 = 
    match replicas with
    | [] -> true
    | (r::replicas) ->
      let log2 = commited_requests r in
      let larger_log_opt = compare_logs log1 log2 in
      match larger_log_opt with
      | None -> false
      | Some(log) -> inner replicas log in
  inner replicas []

let rec finished_workloads clients = 
  match clients with
  | [] -> true
  | (c::clients) -> (finished_workload c) && (finished_workloads clients)
