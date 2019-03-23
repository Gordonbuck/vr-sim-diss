open Core

module GilbertElliottModel = struct 

  type state = Good | Bad

  type t = {p: float; q : float; state: state}    

  let init p q = assert(p +. q = 1.); {p = p; q = q; state = Good}

  let tick model = 
    let r = Random.float 1. in
    match model.state with
    | Good -> 
      if r < model.p then (model.state, model)
      else 
        let model = {model with state = Bad;} in
        (model.state , model)
    | Bad ->
      if r < model.q then (model.state, model)
      else 
        let model = {model with state = Good;} in
        (model.state , model)

end

let sample_uniform a b = 
  let x = Random.float 1. in
  a +. (x *. (b -. a))

let sample_stdnormal_boxmuller () = 
  let u1 = Random.float 1. in
  let u2 = Random.float 1. in
  let z0 = (sqrt ((-. 2.) *. (log u1))) *. (Float.cos (2. *. Float.pi *. u2)) in
  let _ = (sqrt ((-. 2.) *. (log u1))) *. (Float.sin (2. *. Float.pi *. u2)) in
  z0

let sample_normal_boxmuller mu stdv = 
  let x = sample_stdnormal_boxmuller () in
  stdv *. x +. mu

let sample_truncatednormal_boxmuller mu stdv lower = 
  let rec repeat () = 
    let x = sample_normal_boxmuller mu stdv in
    if x >= lower then x else repeat () in
  repeat ()
