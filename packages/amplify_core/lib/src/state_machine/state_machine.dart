// Copyright 2022 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';

import 'package:amplify_core/amplify_core.dart';
import 'package:async/async.dart';
import 'package:meta/meta.dart';

/// Interface for dispatching an event to a state machine.
@optionalTypeArgs
abstract class Dispatcher<E extends StateMachineEvent> {
  /// Dispatches an event.
  void dispatch(E event);
}

/// Interface for emitting a state from a state machine.
abstract class Emitter<S extends StateMachineState> {
  /// Emits a new state.
  void emit(S state);
}

/// {@template amplify_common.state_machine_type}
/// A marker for state machine types to improve DX with generic functions.
/// {@endtemplate}
class StateMachineType<E extends StateMachineEvent, S extends StateMachineState,
    M extends StateMachine<E, S>> {
  /// {@macro amplify_common.state_machine_type}
  const StateMachineType();
}

/// Constructor for a state machine of type [M].
typedef StateMachineBuilder<M extends StateMachine> = M Function(
    StateMachineManager);

/// {@template amplify_common.state_machine_manager}
/// Service locator for state machines to ease communication between the
/// different layers.
/// {@endtemplate}
@optionalTypeArgs
abstract class StateMachineManager<E extends StateMachineEvent>
    implements DependencyManager, Dispatcher<E>, Closeable {
  /// {@macro amplify_common.state_machine_manager}
  StateMachineManager(this._stateMachineBuilders, this._dependencyManager) {
    addInstance<Dispatcher>(this);
  }

  final DependencyManager _dependencyManager;
  final Map<Type, StateMachineBuilder> _stateMachineBuilders;
  final Map<Type, StateMachine> _stateMachines = {};

  final StreamController<StateMachineState> _stateController =
      StreamController.broadcast(sync: true);
  final StreamController<Transition> _transitionController =
      StreamController.broadcast(sync: true);

  /// The unified state stream for all state machines.
  Stream<StateMachineState> get stream => _stateController.stream;

  /// The unified state machine transitions.
  Stream<Transition> get transitions => _transitionController.stream;

  /// Returns the state machine instance for [M].
  ///
  /// Throws a [StateError] if [create] is `true` and no instance or builder
  /// is found.
  M getStateMachine<M extends StateMachine>({
    bool create = true,
  }) {
    if (_stateMachines.containsKey(M)) {
      return _stateMachines[M] as M;
    }
    if (!create) {
      throw StateError('No state machine found for type $M');
    }
    return createStateMachine<M>();
  }

  /// Creates a state machine of type [M] using its registered builder.
  ///
  /// Throws a [StateError] if no builder is registered.
  M createStateMachine<M extends StateMachine>() {
    // Close the current instance, if any.
    _stateMachines[M]?.close();

    final builder = _stateMachineBuilders[M];
    if (builder == null) {
      throw StateError('No builder for state machine $M');
    }
    return (_stateMachines[M] = builder.call(this)) as M;
  }

  @override
  void addBuilder<T extends Object>(
    DependencyBuilder<T> builder, [
    Token<T>? token,
  ]) {
    _dependencyManager.addBuilder<T>(builder, token);
  }

  @override
  void addInstance<T extends Object>(
    T instance, [
    Token<T>? token,
  ]) {
    _dependencyManager.addInstance<T>(instance, token);
  }

  @override
  T? get<T extends Object>([Token<T>? token]) =>
      _dependencyManager.get<T>(token);

  @override
  T getOrCreate<T extends Object>([Token<T>? token]) =>
      _dependencyManager.getOrCreate<T>(token);

  @override
  T create<T extends Object>([Token<T>? token]) =>
      _dependencyManager.create<T>(token);

  @override
  T expect<T extends Object>([Token<T>? token]) =>
      _dependencyManager.expect<T>(token);

  /// Dispatches an event to the appropriate state machine.
  @override
  Future<void> dispatch(E event);

  /// Closes the state machine manager and all state machines.
  @override
  Future<void> close() async {
    await Future.wait<void>(
        _stateMachines.values.map((stateMachine) => stateMachine.close()));
    await _transitionController.close();
    await _stateController.close();
  }
}

/// {@template amplify_common.state_machine}
/// Base class for state machines.
/// {@endtemplate}
abstract class StateMachine<E extends StateMachineEvent,
        S extends StateMachineState>
    implements StreamSink<E>, Emitter<S>, StateMachineManager {
  /// {@macro amplify_common.state_machine}
  StateMachine(this._manager) {
    _init();
  }

  /// Initializes the state machine by subscribing to the event stream and
  /// registering a callback for internal errors.
  void _init() {
    // Use `runtimeType` instead of generics. For some reason, having a method
    // on StateMachineManager to do this generically did not work.
    _manager._stateMachines[runtimeType] = this;

    // Registers `this` as the emitter for states of type [S].
    addInstance<Emitter<S>>(this);

    // Activate the event stream and begin listening for events.
    _listenForEvents();
  }

  // Resolve every event which meets the precondition given the current state,
  // blocking on the current event until it has finished processing.
  Future<void> _listenForEvents() async {
    await for (final event in _eventStream) {
      try {
        if (!_checkPrecondition(event)) {
          continue;
        }
        _currentEvent = event;
        // Resolve in the next event loop since `emit` is synchronous and may
        // fire before listeners are registered.
        await Future.delayed(Duration.zero, () => resolve(event));
      } on Exception catch (error, st) {
        final resolution = resolveError(error, st);

        // Add the error to the state stream if it cannot be resolved to a new
        // state internally.
        if (resolution == null) {
          _stateController.addError(error, st);
          continue;
        }

        emit(resolution);
      }
    }
  }

  /// The current event being handled by the state machine.
  late E _currentEvent;

  /// Emits a new state synchronously for the current event.
  @override
  void emit(S state) {
    _stateController.add(state);
    _manager._stateController.add(state);
    final transition = Transition(
      _currentState,
      _currentEvent,
      state,
    );
    _transitionController.add(transition);
    _manager._transitionController.add(transition);
    _currentState = state;
  }

  /// Checks the precondition on [event] given [currentState]. If it fails,
  /// return `false` to skip the event.
  bool _checkPrecondition(E event) {
    final precondError = event.checkPrecondition(currentState);
    if (precondError != null) {
      // TODO(dnys1): Log
      // ignore:avoid_print
      print('Precondition not met for event: $event ($precondError)');
      return false;
    }

    return true;
  }

  final StateMachineManager _manager;

  /// State controller.
  @override
  final StreamController<S> _stateController =
      StreamController.broadcast(sync: true);

  /// Event controller.
  final StreamController<E> _eventController = StreamController();

  /// Transition controller.
  @override
  final StreamController<Transition<E, S>> _transitionController =
      StreamController.broadcast(sync: true);

  /// Subscriptions of this state machine to others.
  final Map<StateMachineType, StreamSubscription> _subscriptions = {};

  /// The stream of events added to this state machine.
  late final Stream<E> _eventStream = _eventController.stream;

  /// The initial state of the state machine.
  S get initialState;

  late S _currentState = initialState;

  /// The state machine's current state.
  S get currentState => _currentState;

  /// Transforms events into state changes.
  Future<void> resolve(E event);

  /// Resolves an error thrown inside the state machine.
  ///
  /// If the error cannot be resolved, return `null` and the error will be
  /// rethrown.
  S? resolveError(Object error, [StackTrace? st]);

  /// The stream of state machine states.
  @override
  Stream<S> get stream => _stateController.stream;

  @override
  Stream<Transition<E, S>> get transitions => _transitionController.stream;

  @override
  void addBuilder<T extends Object>(
    DependencyBuilder<T> builder, [
    Token<T>? token,
  ]) =>
      _manager.addBuilder<T>(builder, token);

  @override
  void addInstance<T extends Object>(
    T instance, [
    Token<T>? token,
  ]) =>
      _manager.addInstance<T>(instance, token);

  @override
  T? get<T extends Object>([Token<T>? token]) => _manager.get<T>(token);

  @override
  T getOrCreate<T extends Object>([Token<T>? token]) =>
      _manager.getOrCreate<T>(token);

  @override
  T expect<T extends Object>([Token<T>? token]) => _manager.expect<T>(token);

  @override
  T create<T extends Object>([Token<T>? token]) => _manager.create<T>(token);

  @override
  M getStateMachine<M extends StateMachine>({bool create = true}) =>
      _manager.getStateMachine<M>();

  @override
  M createStateMachine<M extends StateMachine>() =>
      _manager.createStateMachine<M>();

  /// Subscribes to the state machine of the given type.
  void subscribeTo<SE extends StateMachineEvent, SS extends StateMachineState,
      M extends StateMachine<SE, SS>>(
    StateMachineType<SE, SS, M> type,
    void Function(SS state) onData,
  ) {
    if (_subscriptions.containsKey(type)) {
      SubscriptionStream(_subscriptions[type]! as StreamSubscription<SS>)
          .listen(
        onData,
        cancelOnError: true,
      );
    } else {
      _subscriptions[type] = _manager.getStateMachine<M>().stream.listen(
            onData,
            cancelOnError: true,
          );
    }
  }

  @override
  void add(E event) => _eventController.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _eventController.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<E> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  /// Dispatches an event to the state machine.
  @override
  Future<void> dispatch(StateMachineEvent event) => _manager.dispatch(event);

  /// Closes the state machine and all stream controllers.
  @override
  Future<void> close() async {
    await Future.wait(_subscriptions.values.map((sub) => sub.cancel()));
    await _transitionController.close();
    await _eventController.close();
    await _stateController.close();
  }

  @override
  Future<void> get done => _eventController.done;
}
