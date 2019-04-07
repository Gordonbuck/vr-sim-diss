open Core
open OUnit2

let index_tests = 
  "index_tests">:::
  (List.map
     [(-1, -1);
      (0, 0);
      (7, 7)]
     (fun (arg,res) ->
        let title =
          Printf.sprintf "%i->%i" arg res
        in
        title >::
        (fun test_ctxt ->
           assert_equal res (VR_State.int_of_index (VR_State.index_of_int arg)))))

let index_of_client_tests = 
  let clients = VR_State.init_clients 10 3 in
  "index_of_client_tests">:::
  (List.map
     [(List.nth_exn clients 0, 0);
      (List.nth_exn clients 1, 1)]
     (fun (arg,res) ->
        let title =
          Printf.sprintf "client->%i" res
        in
        title >::
        (fun test_ctxt ->
           assert_equal res (VR_State.index_of_client arg))))

let index_of_replica_tests = 
  let replicas = VR_State.init_replicas 10 3 in
  "index_of_replica_tests">:::
  (List.map
     [(List.nth_exn replicas 0, 0);
      (List.nth_exn replicas 1, 1);
      (List.nth_exn replicas 7, 7)]
     (fun (arg,res) ->
        let title =
          Printf.sprintf "replica->%i" res
        in
        title >::
        (fun test_ctxt ->
           assert_equal res (VR_State.index_of_replica arg))))

let n_replicas_tests = 
  let replicas = VR_State.init_replicas 10 3 in
  let replica_1 = List.nth_exn replicas 1 in
  let replicas = VR_State.init_replicas 7 3 in
  let replica_2 = List.nth_exn replicas 2 in
  let replicas = VR_State.init_replicas 1 3 in
  let replica_0 = List.nth_exn replicas 0 in
  "n_replicas_tests">:::
  (List.map
     [(replica_1, 10);
      (replica_2, 7);
      (replica_0, 1)]
     (fun (arg,res) ->
        let title =
          Printf.sprintf "replica->%i" res
        in
        title >::
        (fun test_ctxt ->
           assert_equal res (VR_State.n_replicas arg))))

let client_n_replicas_tests = 
  let clients = VR_State.init_clients 3 3 in
  let client_1 = List.nth_exn clients 1 in
  let clients = VR_State.init_clients 5 3 in
  let client_2 = List.nth_exn clients 2 in
  let clients = VR_State.init_clients 1 3 in
  let client_0 = List.nth_exn clients 0 in
  "client_n_replicas_tests">:::
  (List.map
     [(client_1, 3);
      (client_2, 5);
      (client_0, 1)]
     (fun (arg,res) ->
        let title =
          Printf.sprintf "client->%i" res
        in
        title >::
        (fun test_ctxt ->
           assert_equal res (VR_State.client_n_replicas arg))))

let simtime_inc_tests = 
  let t = SimTime.t_of_float 10. in
  "simtime_inc_tests">:::
  (List.map
     [(0., 10.);
      (5., 15.);
      (7., 17.)]
     (fun (arg,res) ->
        let title =
          Printf.sprintf "%f->%f" arg res
        in
        title >::
        (fun test_ctxt ->
           assert_equal res (SimTime.float_of_t (SimTime.inc t (SimTime.span_of_float arg))))))

let simtime_compare_tests = 
  let t = SimTime.t_of_float 10. in
  "simtime_inc_tests">:::
  (List.map
     [(10., 0);
      (7., -1);
      (12., 1)]
     (fun (arg,res) ->
        let title =
          Printf.sprintf "%f->%i" arg res
        in
        title >::
        (fun test_ctxt ->
           assert_equal res (SimTime.compare (SimTime.t_of_float arg) t))))

let force_unwrap opt = 
  match opt with 
  | Some(a) -> a
  | None -> assert(false)

let eventlist_tests = 
  let cmp a b = a - b in
  let heap = EventList.EventHeap.create cmp in
  let heap = EventList.EventHeap.add_multi heap [1;4;2] in
  let heap = EventList.EventHeap.add_multi heap [] in
  let heap = EventList.EventHeap.add heap 3 in
  let (res1, heap) = force_unwrap (EventList.EventHeap.pop heap) in
  let (res2, heap) = force_unwrap (EventList.EventHeap.pop heap) in
  let (res3, heap) = force_unwrap (EventList.EventHeap.pop heap) in
  "eventlist_tests">:::
  (List.map
     [(res1, 1);
      (res2, 2);
      (res3, 3)]
     (fun (arg,res) ->
        let title =
          Printf.sprintf "pop->%i" res
        in
        title >::
        (fun test_ctxt ->
           assert_equal res arg)))

let () = 
  run_test_tt_main (test_list [index_tests;index_of_client_tests;index_of_replica_tests;
                               n_replicas_tests;client_n_replicas_tests;
                               simtime_inc_tests;simtime_compare_tests;eventlist_tests])
