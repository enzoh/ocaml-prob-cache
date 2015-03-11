open Prob_cache_common
module OldList = List
module OldSequence = Sequence
open Core.Std
module Float = CCFloat (* for pretty printing, ord, etc *)
module CoreList = List
module List = CCList
open Async.Std

module Sequence = OldSequence

(** Represents a single event- must be protobuf capable, comparable, and pretty printable *)  
module type EVENT = 
sig 
  type t [@@deriving protobuf, show, ord]
  include Events_common.EVENT with type t := t
end

(** Represents an abstract collection of events, must be protobuf capable and pretty printable *)
module type EVENTS = 
sig 
  type t [@@deriving protobuf, show]
  module Event : EVENT
  include Events_common.EVENTS with module Event := Event and type t := t
end

module Data = Model_intf.Data 

(** A module type provided polymorphic probability model caches. Uses in distributed models backed by riak *)
module type S =
sig
  (** The module type representing a collection of events *)
  module Events : EVENTS

  (** The module type representing one event *)
  module Event : module type of Events.Event

  (** The riak cache backing the probability model. *)
  module Cache : module type of Cache.Make(Events)(Data)

  (** Defines a prior function in terms of counts with the observed events as input. *)
  type prior_count = Events.t -> int

  (** Define a prior function in terms of real values with the observed events as input. *)
  type prior_exp = Events.t -> float

  (** A probability model cache *)
  type t

  (** Defines the update rule for expectations *)
  type update_rule = Events.t Update_rules.Update_fn.t

  val count : Events.t -> t -> (int, [> Opts.Get.error]) Deferred.Result.t
  (** How many times [events] was observed for the model cache [t].
      Errors during the riak fetch routine are propogated back in the deferred result. *)

  val observe : ?cnt:int -> ?exp:float -> Events.t -> t -> 
    (t, [> Opts.Put.error | Opts.Get.error | Conn.error ]) Deferred.Result.t
  (** Observe a sequence with a default count and expectation of 1. *)

  val prob : ?cond:Events.t -> Events.t -> t -> (float, [> Opts.Get.error]) Deferred.Result.t  
  (** Probability of events given observed events, possibly the empty events *)

  val exp : ?cond:Events.t -> Events.t -> t -> (float, [> Opts.Get.error]) Deferred.Result.t
  (** Expectation of events given observed events, possibly the empty events *)

  val name : t -> string
  (** Gets the name of the cache *)

  val with_model : ?update_rule:update_rule -> ?prior_count:prior_count -> ?prior_exp:prior_exp -> 
    host:string -> port:int -> name:string -> 
    (t -> ('a, [> Conn.error] as 'e) Deferred.Result.t) -> 
         ('a, 'e) Deferred.Result.t
  (** Execute a deferred function for the specified model where [name] corresponds to a riak bucket for
     the given [host] and [port] *) 
end

module Make_for_events (Events:EVENTS) : S with module Events = Events =
struct
  module Events = Events
  module Event = Events.Event
  module Cache = Cache.Make(Events)(Data)
  module Int = CCInt
  
  type prior_count = Events.t -> int
  type prior_exp = Events.t -> float

  type update_rule = Events.t Update_rules.Update_fn.t

  and t = {
    name : string; 
    cache : Cache.t; 
    prior_count : prior_count; 
    prior_exp : prior_exp; 
    update_rule : update_rule }

  let default_prior_count (e:Events.t) = 0

  let default_prior_exp (e:Events.t) = 0.

  let default_update_rule : update_rule = Update_rules.mean

  let create ?(update_rule=default_update_rule) ?(prior_count=default_prior_count) 
    ?(prior_exp=default_prior_exp) cache =
      {cache;prior_count;prior_exp;update_rule;name=Cache.get_bucket cache}

  let data events t =
   let open Cache.Robj in Cache.get t.cache events >>| function 
    | Ok robj -> 
        (match robj.contents with  
      | [] -> Ok None
      | [d] -> Ok (Some (Content.value d))
      | l -> failwith "should only be one content value")
    | Error `Notfound -> Ok None 
    | Error e -> Error e

  let count (events:Events.t) t : (int, [> Opts.Get.error]) Result.t Deferred.t  = 
  let open Cache.Robj in data events t >>| function 
    | Ok (Some data) -> Ok (Data.count data) 
    | Ok None -> Ok (t.prior_count events)
    | Error e -> Error e

  let exp ?(cond=Events.empty) (events:Events.t) t = 
    let open Deferred.Result.Monad_infix in 
    let joined_events = Events.join cond events in
    data joined_events t >>| fun d -> CCOpt.get_lazy (fun () -> t.prior_exp events) (CCOpt.map (fun d' -> Data.expect d') d)

  let prob ?(cond=Events.empty) (events:Events.t) t : (Core.Std.Float.t, [> Opts.Get.error]) Result.t Deferred.t  =
    let open Deferred.Result.Monad_infix in 
    count (Events.join events cond) t >>= 
    fun event_count -> count cond t >>= 
    fun given_cond_count -> (if given_cond_count = 0 && (not (Events.is_empty cond)) 
                             then count Events.empty t else Deferred.return (Ok given_cond_count))
    >>| fun cond_count -> if (cond_count = 0) then Float.of_int 0 else
      (Float.of_int event_count) /. (Float.of_int cond_count)


  let update ?(cnt=1) ?(exp=1.0) (events:Events.t) (t:t) =
    let open Deferred.Result.Monad_infix in
    let open Cache.Robj in data events t >>= 
    fun d_opt -> let d = Data.update 
      ~cnt ~exp 
      ~update_rule:t.update_rule 
      ~prior_count:t.prior_count ~prior_exp:t.prior_exp 
      events 
      d_opt in
    Cache.put t.cache ~k:events (Cache.Robj.of_value d)

  let observe ?(cnt=1) ?(exp=1.0) (events:Events.t) t =
    let open Deferred.Result.Monad_infix in
    let subsets = Events.subsets events in
    List.fold_right 
    (fun e d -> Deferred.Result.ignore (Deferred.Result.bind d (fun _ -> update ~cnt ~exp e t))) subsets (Deferred.Result.return ())
    >>| fun (_:unit) -> t

  let with_model ?update_rule ?prior_count
    ?prior_exp ~host ~port ~(name:string) f =
      let open Deferred.Result.Monad_infix in
      Cache.with_cache ~host ~port ~bucket:name (fun c -> 
        let (m:t) = create ?prior_count ?update_rule ?prior_exp c in f m)

  let name t = t.name
end

module Make_event_set(Event:EVENT) : EVENTS with module Event = Event = 
struct
  module Event = Event
  module Hashset = Containers_misc.Hashset
  type t = Event.t Hashset.t

  let to_list t = List.sort_uniq ~cmp:Event.compare (Sequence.to_list (Hashset.to_seq t))
  let of_list l = 
    let h = Hashset.empty (CoreList.length l) in 
    CoreList.iter ~f:(fun e -> Hashset.add h e) l;h 

  module List = OldList
  type event_list = Event.t list [@@deriving protobuf]

  let join (t:t) (t':t) : t = Hashset.union t t'
  let empty = of_list []
  let is_empty t = Hashset.cardinal t = 0

  let subsets (t:t) : t list = 
    List.map of_list (Util.powerset (to_list t))

  let to_protobuf t e =  event_list_to_protobuf (to_list t) e
  let from_protobuf d = of_list (event_list_from_protobuf d)

let pp (f:Format.formatter) t = Hashset.iter (fun e -> Event.pp f e) t
let show t =  Hashset.fold (fun acc e -> (Event.show e) ^ ";" ^ acc) "" t 

end



module Make_event_sequence(Event:EVENT) : EVENTS with module Event = Event =
struct
  module Event = Event
  module List = OldList 
  type t = Event.t list [@@deriving protobuf, show]
  let of_list l = l
  let to_list l = l
  let join = CCList.append
  let empty = CCList.empty
  let subsets (l:t) = let (accum, _ ) = 
    List.fold_left 
      (fun ((accum: t list), (l:t)) e -> let l' = l@[e] in (l'::accum, l')) 
      ([], []) 
      l
  in
  []::accum
  let is_empty t = empty = t
end
