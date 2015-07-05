(** A abstract model, defining the type of events and data structures
to maintain their probabilities and expectations.
*)

(** Floating point convenience module *)
module Float = CCFloat
open Events_common

module type MONAD =
  sig
    type 'a t
    val map :  ('a -> 'b) -> 'a t -> 'b t
    val bind : ('a -> 'b t) -> 'a t -> 'b t
    val return : 'a -> 'a t
    val all : 'a t list -> 'a list t
    val both : 'a t -> 'b t -> ('a * 'b) t
    module Infix :
      sig
        val (>>|) : 'a t -> ('a -> 'b) -> 'b t
        val (>|=) : 'a t -> ('a -> 'b) -> 'b t
        val (>>=) : 'a t -> ('a -> 'b t) -> 'b t
      end
  end

module type RESULT =
  sig
    type ('ok, 'err) t = Ok of 'ok | Error of 'err 
    val map : ('ok -> 'res) -> ('ok, 'err) t -> ('res, 'err) t
    val bind : ('ok -> ('res, 'err) t) -> ('ok, 'err) t -> ('res, 'err) t
    val return: 'ok -> ('ok, 'err) t
    val all : ('ok, 'err) t list -> ('ok list, 'err) t
    val both : ('ok, 'err) t -> ('ok, 'err) t -> ('ok * 'ok, 'err) t

    module Monad_infix :
      sig
        val (>>|) : ('ok, 'err) t -> ('ok -> 'res) -> ('res, 'err) t
        val (>|=) : ('ok, 'err) t -> ('ok -> 'res) ->  ('res, 'err) t
        val (>>=) : ('ok, 'err) t -> ('ok -> ('res, 'err) t) -> ('res, 'err) t
      end
  end

module type ERROR =
sig
  type t
  val to_string_hum : t -> string
  val to_string_mach : t -> string
end

module type CREATE_FUN =
sig

  type t
  module Result : RESULT
  module Create_error : ERROR

  (** The module type representing a collection of events *)
  module Events : EVENTS

  (** Container for the descriptive statistics **)
  module Data : Data.S

  (* Defines a prior function in terms of counts with the observed events as input. *)
  type prior_count = Events.t -> int

  (* Define a prior function in terms of real values with the observed events as input. *)
  type prior_exp = Events.t -> float

  (** Defines the update rule for expectations *)
  type update_rule = Events.t Data.update_rule
  val update_rule : t -> update_rule

  type 'err create =
    ?update_rule:update_rule -> ?prior_count:prior_count ->
      ?prior_exp:prior_exp -> name:string -> (t, 'err) Result.t

  val create : Create_error.t create
  (** Creates a new model cache labeled by the given string. By default, expectations are updated
     using a mean value estimator and all priors are value 0. *)
end

module type OBSERVE_FUN =
sig

  type t
  module Result : RESULT
  module Observe_error : ERROR

  (** The module type representing a collection of events *)
  module Events : EVENTS

  (** Container for the descriptive statistics **)
  module Data : Data.S

  type 'err observe = Data.t -> Events.t -> t -> (t, 'err) Result.t

  val observe : Observe_error.t observe
  (** Observe events from a [data] instance of descriptive statistics. This
    can be used to batch updates, or to load independently generated datasets
    together in a meaningful way. The returned model reflects the observation
    updates while the original instance is not guaranteed to be current. *)
end

module type DATA_FUN =
sig

  type t
  module Result : RESULT
  module Data_error : ERROR

  (** The module type representing a collection of events *)
  module Events : EVENTS

  (** Container for the descriptive statistics **)
  module Data : Data.S

  type 'err data = Events.t -> t -> (Data.t, 'err) Result.t

  val data : Data_error.t data
  (** Gets the descriptive statistics data for the given events. 
      Returns data with count of zero otherwise and other values set to nan. *)

end

module type FIND_FUN =
sig

  type t
  module Result : RESULT
  module Find_error : ERROR

  (** The module type representing a collection of events *)
  module Events : EVENTS

  (** Container for the descriptive statistics **)
  module Data : Data.S

  type 'err find = (Events.t -> bool) -> t -> (Events.t, Find_error.t) Result.t
  (** Gets all observed events given a filter function from the model. *)

  val find : Find_error.t find
  (** Gets all observed events given a filter function from the model. *)

end


(** A module type provided polymorphic probability model caches. Uses in memory models backed by the containers api *)
module type S =
sig

  module Result : RESULT

  (** The module type representing one event *)
  module Event : EVENT

  (** The module type representing a collection of events *)
  module Events : EVENTS with module Event = Event

  module Data : Data.S
    (** An abstract events model cache *)
  type t

  include CREATE_FUN with
    module Events := Events and
    module Result := Result and
    module Data := Data and
    type t := t

  include OBSERVE_FUN with
    module Events := Events and
    module Result := Result and
    module Data := Data and
    type t := t

  include DATA_FUN with
    module Events := Events and
    module Result := Result and
    module Data := Data and
    type t := t

  include FIND_FUN with
    module Events := Events and
    module Result := Result and
    module Data := Data and
    type t := t

  val name : t -> string
  (** Gets the name of the cache *)

  (** Simpler interface that unifies the error type *)
  module Or_errors :
    sig
      module Or_error : MONAD with type 'a t = ('a,
      [ `Create_error of Create_error.t
      | `Observe_error of Observe_error.t
      | `Data_error of Data_error.t
      | `Find_error of Find_error.t]) Result.t

      val update_rule : t -> update_rule
      val create : t Or_error.t create
      val observe : t Or_error.t observe
      val data : t Or_error.t data
      val find : t Or_error.t find
      val name : t -> string
  end
end

module Make
  (Result : RESULT)
  (Events : EVENTS)
  (Data : Data.S)
  (Create_fun : CREATE_FUN)
  (Observe_fun : OBSERVE_FUN)
  (Data_fun : DATA_FUN)
  (Find_fun : FIND_FUN)
 : S =
struct
  include Create_fun
  module Event = Events.Event
  include (Data_fun : DATA_FUN with
    type t := t and
    module Result := Result and
    module Events := Events and
    module Data := Data)

end

