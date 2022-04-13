import 'dart:async';

import '../../../api.dart' as api;
import '../../../sdk.dart' as sdk;

/// An interface for creating [api.Span]s and propagating context in-process.
class Tracer implements api.Tracer {
  final List<api.SpanProcessor> _processors;
  final api.Resource _resource;
  final api.Sampler _sampler;
  final api.IdGenerator _idGenerator;
  final api.InstrumentationLibrary _instrumentationLibrary;
  sdk.SpanLimits _spanLimits;

  Tracer(this._processors, this._resource, this._sampler, this._idGenerator,
      this._instrumentationLibrary,
      {sdk.SpanLimits spanLimits}) {
    _spanLimits = spanLimits ?? sdk.SpanLimits();
  }

  @override
  api.Span startSpan(String name,
      {api.Context context, List<api.Attribute> attributes}) {
    context ??= api.Context.current;

    // If a valid, active Span is present in the context, use it as this Span's
    // parent.  If the Context does not contain an active parent Span, create
    // a root Span with a new Trace ID and default state.
    // See https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md#determining-the-parent-span-from-a-context
    final parent = context.span;
    final spanId = api.SpanId.fromIdGenerator(_idGenerator);
    api.TraceId traceId;
    api.TraceState traceState;
    api.SpanId parentSpanId;

    if (parent != null) {
      parentSpanId = parent.spanContext.spanId;
      traceId = parent.spanContext.traceId;
      traceState = parent.spanContext.traceState;
    } else {
      parentSpanId = api.SpanId.root();
      traceId = api.TraceId.fromIdGenerator(_idGenerator);
      traceState = sdk.TraceState.empty();
    }

    final samplerResult =
        _sampler.shouldSample(context, traceId, name, false, attributes);
    final traceFlags = (samplerResult.decision == api.Decision.recordAndSample)
        ? api.TraceFlags.sampled
        : api.TraceFlags.none;
    final spanContext =
        sdk.SpanContext(traceId, spanId, traceFlags, traceState);

    return sdk.Span(name, spanContext, parentSpanId, _processors, _resource,
        _instrumentationLibrary,
        attributes: attributes, spanlimits: _spanLimits);
  }

  /// Records a span of the given [name] for the given function
  /// and marks the span as errored if an exception occurs.
  @override
  FutureOr<R> trace<R>(String name, FutureOr<R> Function() fn,
      {api.Context context}) async {
    context ??= api.Context.current;
    final span = startSpan(name, context: context);

    try {
      var result = context.withSpan(span).execute(fn);
      if (result is Future) {
        // Operation must be awaited here to ensure the catch block intercepts
        // errors thrown by [fn].
        result = await result;
      }
      return result;
    } catch (e, s) {
      span.recordException(e, stackTrace: s);
      rethrow;
    } finally {
      span.end();
    }
  }
}
