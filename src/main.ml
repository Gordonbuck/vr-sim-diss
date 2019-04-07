open Core
open Simulator

let sim_runs () = 
  let params_n = 1 in
  let n_iterations = 100 in
  let module VR_Sim = Simulator(VR)(VR_Params) in
  let rec run i =
    if i = n_iterations then ()
    else
      let newstdout = Out_channel.create (Printf.sprintf "data/params%i/trace_%i" params_n i) in
      Unix.dup2 (Unix.descr_of_out_channel newstdout) Unix.stdout;
      VR_Sim.run ();
      Out_channel.close newstdout;
      run (i+1) in
  run 0

let main () =
  let module VR_Sim = Simulator(VR)(VR_Params) in
  VR_Sim.run ()

let () = main ()
