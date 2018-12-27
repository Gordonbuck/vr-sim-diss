type t = int
type span = int

let compare t1 t2 = t1 - t2

let diff t1 t2 = abs (t1 - t2)

let inc t s = t + s