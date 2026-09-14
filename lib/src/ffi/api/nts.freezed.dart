// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'nts.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$NtsClockFault {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'NtsClockFault()';
}


}

/// @nodoc
class $NtsClockFaultCopyWith<$Res>  {
$NtsClockFaultCopyWith(NtsClockFault _, $Res Function(NtsClockFault) __);
}


/// Adds pattern-matching-related methods to [NtsClockFault].
extension NtsClockFaultPatterns on NtsClockFault {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( NtsClockFault_Unsupported value)?  unsupported,TResult Function( NtsClockFault_SyscallFailed value)?  syscallFailed,TResult Function( NtsClockFault_TimebaseUnavailable value)?  timebaseUnavailable,TResult Function( NtsClockFault_InvalidRaw value)?  invalidRaw,TResult Function( NtsClockFault_ConversionOverflow value)?  conversionOverflow,TResult Function( NtsClockFault_Regression value)?  regression,TResult Function( NtsClockFault_GenerationChanged value)?  generationChanged,TResult Function( NtsClockFault_SuspendedInFlight value)?  suspendedInFlight,required TResult orElse(),}){
final _that = this;
switch (_that) {
case NtsClockFault_Unsupported() when unsupported != null:
return unsupported(_that);case NtsClockFault_SyscallFailed() when syscallFailed != null:
return syscallFailed(_that);case NtsClockFault_TimebaseUnavailable() when timebaseUnavailable != null:
return timebaseUnavailable(_that);case NtsClockFault_InvalidRaw() when invalidRaw != null:
return invalidRaw(_that);case NtsClockFault_ConversionOverflow() when conversionOverflow != null:
return conversionOverflow(_that);case NtsClockFault_Regression() when regression != null:
return regression(_that);case NtsClockFault_GenerationChanged() when generationChanged != null:
return generationChanged(_that);case NtsClockFault_SuspendedInFlight() when suspendedInFlight != null:
return suspendedInFlight(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( NtsClockFault_Unsupported value)  unsupported,required TResult Function( NtsClockFault_SyscallFailed value)  syscallFailed,required TResult Function( NtsClockFault_TimebaseUnavailable value)  timebaseUnavailable,required TResult Function( NtsClockFault_InvalidRaw value)  invalidRaw,required TResult Function( NtsClockFault_ConversionOverflow value)  conversionOverflow,required TResult Function( NtsClockFault_Regression value)  regression,required TResult Function( NtsClockFault_GenerationChanged value)  generationChanged,required TResult Function( NtsClockFault_SuspendedInFlight value)  suspendedInFlight,}){
final _that = this;
switch (_that) {
case NtsClockFault_Unsupported():
return unsupported(_that);case NtsClockFault_SyscallFailed():
return syscallFailed(_that);case NtsClockFault_TimebaseUnavailable():
return timebaseUnavailable(_that);case NtsClockFault_InvalidRaw():
return invalidRaw(_that);case NtsClockFault_ConversionOverflow():
return conversionOverflow(_that);case NtsClockFault_Regression():
return regression(_that);case NtsClockFault_GenerationChanged():
return generationChanged(_that);case NtsClockFault_SuspendedInFlight():
return suspendedInFlight(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( NtsClockFault_Unsupported value)?  unsupported,TResult? Function( NtsClockFault_SyscallFailed value)?  syscallFailed,TResult? Function( NtsClockFault_TimebaseUnavailable value)?  timebaseUnavailable,TResult? Function( NtsClockFault_InvalidRaw value)?  invalidRaw,TResult? Function( NtsClockFault_ConversionOverflow value)?  conversionOverflow,TResult? Function( NtsClockFault_Regression value)?  regression,TResult? Function( NtsClockFault_GenerationChanged value)?  generationChanged,TResult? Function( NtsClockFault_SuspendedInFlight value)?  suspendedInFlight,}){
final _that = this;
switch (_that) {
case NtsClockFault_Unsupported() when unsupported != null:
return unsupported(_that);case NtsClockFault_SyscallFailed() when syscallFailed != null:
return syscallFailed(_that);case NtsClockFault_TimebaseUnavailable() when timebaseUnavailable != null:
return timebaseUnavailable(_that);case NtsClockFault_InvalidRaw() when invalidRaw != null:
return invalidRaw(_that);case NtsClockFault_ConversionOverflow() when conversionOverflow != null:
return conversionOverflow(_that);case NtsClockFault_Regression() when regression != null:
return regression(_that);case NtsClockFault_GenerationChanged() when generationChanged != null:
return generationChanged(_that);case NtsClockFault_SuspendedInFlight() when suspendedInFlight != null:
return suspendedInFlight(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  unsupported,TResult Function( int errno)?  syscallFailed,TResult Function( int kernReturn,  int numer,  int denom)?  timebaseUnavailable,TResult Function()?  invalidRaw,TResult Function()?  conversionOverflow,TResult Function( PlatformInt64 previous,  PlatformInt64 observed)?  regression,TResult Function( PlatformInt64 expected,  PlatformInt64 observed)?  generationChanged,TResult Function( PlatformInt64 boottimeMicros,  PlatformInt64 monotonicMicros)?  suspendedInFlight,required TResult orElse(),}) {final _that = this;
switch (_that) {
case NtsClockFault_Unsupported() when unsupported != null:
return unsupported();case NtsClockFault_SyscallFailed() when syscallFailed != null:
return syscallFailed(_that.errno);case NtsClockFault_TimebaseUnavailable() when timebaseUnavailable != null:
return timebaseUnavailable(_that.kernReturn,_that.numer,_that.denom);case NtsClockFault_InvalidRaw() when invalidRaw != null:
return invalidRaw();case NtsClockFault_ConversionOverflow() when conversionOverflow != null:
return conversionOverflow();case NtsClockFault_Regression() when regression != null:
return regression(_that.previous,_that.observed);case NtsClockFault_GenerationChanged() when generationChanged != null:
return generationChanged(_that.expected,_that.observed);case NtsClockFault_SuspendedInFlight() when suspendedInFlight != null:
return suspendedInFlight(_that.boottimeMicros,_that.monotonicMicros);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  unsupported,required TResult Function( int errno)  syscallFailed,required TResult Function( int kernReturn,  int numer,  int denom)  timebaseUnavailable,required TResult Function()  invalidRaw,required TResult Function()  conversionOverflow,required TResult Function( PlatformInt64 previous,  PlatformInt64 observed)  regression,required TResult Function( PlatformInt64 expected,  PlatformInt64 observed)  generationChanged,required TResult Function( PlatformInt64 boottimeMicros,  PlatformInt64 monotonicMicros)  suspendedInFlight,}) {final _that = this;
switch (_that) {
case NtsClockFault_Unsupported():
return unsupported();case NtsClockFault_SyscallFailed():
return syscallFailed(_that.errno);case NtsClockFault_TimebaseUnavailable():
return timebaseUnavailable(_that.kernReturn,_that.numer,_that.denom);case NtsClockFault_InvalidRaw():
return invalidRaw();case NtsClockFault_ConversionOverflow():
return conversionOverflow();case NtsClockFault_Regression():
return regression(_that.previous,_that.observed);case NtsClockFault_GenerationChanged():
return generationChanged(_that.expected,_that.observed);case NtsClockFault_SuspendedInFlight():
return suspendedInFlight(_that.boottimeMicros,_that.monotonicMicros);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  unsupported,TResult? Function( int errno)?  syscallFailed,TResult? Function( int kernReturn,  int numer,  int denom)?  timebaseUnavailable,TResult? Function()?  invalidRaw,TResult? Function()?  conversionOverflow,TResult? Function( PlatformInt64 previous,  PlatformInt64 observed)?  regression,TResult? Function( PlatformInt64 expected,  PlatformInt64 observed)?  generationChanged,TResult? Function( PlatformInt64 boottimeMicros,  PlatformInt64 monotonicMicros)?  suspendedInFlight,}) {final _that = this;
switch (_that) {
case NtsClockFault_Unsupported() when unsupported != null:
return unsupported();case NtsClockFault_SyscallFailed() when syscallFailed != null:
return syscallFailed(_that.errno);case NtsClockFault_TimebaseUnavailable() when timebaseUnavailable != null:
return timebaseUnavailable(_that.kernReturn,_that.numer,_that.denom);case NtsClockFault_InvalidRaw() when invalidRaw != null:
return invalidRaw();case NtsClockFault_ConversionOverflow() when conversionOverflow != null:
return conversionOverflow();case NtsClockFault_Regression() when regression != null:
return regression(_that.previous,_that.observed);case NtsClockFault_GenerationChanged() when generationChanged != null:
return generationChanged(_that.expected,_that.observed);case NtsClockFault_SuspendedInFlight() when suspendedInFlight != null:
return suspendedInFlight(_that.boottimeMicros,_that.monotonicMicros);case _:
  return null;

}
}

}

/// @nodoc


class NtsClockFault_Unsupported extends NtsClockFault {
  const NtsClockFault_Unsupported(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault_Unsupported);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'NtsClockFault.unsupported()';
}


}




/// @nodoc


class NtsClockFault_SyscallFailed extends NtsClockFault {
  const NtsClockFault_SyscallFailed({required this.errno}): super._();
  

 final  int errno;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsClockFault_SyscallFailedCopyWith<NtsClockFault_SyscallFailed> get copyWith => _$NtsClockFault_SyscallFailedCopyWithImpl<NtsClockFault_SyscallFailed>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault_SyscallFailed&&(identical(other.errno, errno) || other.errno == errno));
}


@override
int get hashCode {
    return Object.hash(runtimeType,errno);
}

@override
String toString() {
    return 'NtsClockFault.syscallFailed(errno: $errno)';
}


}

/// @nodoc
abstract mixin class $NtsClockFault_SyscallFailedCopyWith<$Res> implements $NtsClockFaultCopyWith<$Res> {
  factory $NtsClockFault_SyscallFailedCopyWith(NtsClockFault_SyscallFailed value, $Res Function(NtsClockFault_SyscallFailed) _then) = _$NtsClockFault_SyscallFailedCopyWithImpl;
@useResult
$Res call({
 int errno
});




}
/// @nodoc
class _$NtsClockFault_SyscallFailedCopyWithImpl<$Res>
    implements $NtsClockFault_SyscallFailedCopyWith<$Res> {
  _$NtsClockFault_SyscallFailedCopyWithImpl(this._self, this._then);

  final NtsClockFault_SyscallFailed _self;
  final $Res Function(NtsClockFault_SyscallFailed) _then;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? errno = null,}) {
  return _then(NtsClockFault_SyscallFailed(
errno: null == errno ? _self.errno : errno // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NtsClockFault_TimebaseUnavailable extends NtsClockFault {
  const NtsClockFault_TimebaseUnavailable({required this.kernReturn, required this.numer, required this.denom}): super._();
  

 final  int kernReturn;
 final  int numer;
 final  int denom;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsClockFault_TimebaseUnavailableCopyWith<NtsClockFault_TimebaseUnavailable> get copyWith => _$NtsClockFault_TimebaseUnavailableCopyWithImpl<NtsClockFault_TimebaseUnavailable>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault_TimebaseUnavailable&&(identical(other.kernReturn, kernReturn) || other.kernReturn == kernReturn)&&(identical(other.numer, numer) || other.numer == numer)&&(identical(other.denom, denom) || other.denom == denom));
}


@override
int get hashCode {
    return Object.hash(runtimeType,kernReturn,numer,denom);
}

@override
String toString() {
    return 'NtsClockFault.timebaseUnavailable(kernReturn: $kernReturn, numer: $numer, denom: $denom)';
}


}

/// @nodoc
abstract mixin class $NtsClockFault_TimebaseUnavailableCopyWith<$Res> implements $NtsClockFaultCopyWith<$Res> {
  factory $NtsClockFault_TimebaseUnavailableCopyWith(NtsClockFault_TimebaseUnavailable value, $Res Function(NtsClockFault_TimebaseUnavailable) _then) = _$NtsClockFault_TimebaseUnavailableCopyWithImpl;
@useResult
$Res call({
 int kernReturn, int numer, int denom
});




}
/// @nodoc
class _$NtsClockFault_TimebaseUnavailableCopyWithImpl<$Res>
    implements $NtsClockFault_TimebaseUnavailableCopyWith<$Res> {
  _$NtsClockFault_TimebaseUnavailableCopyWithImpl(this._self, this._then);

  final NtsClockFault_TimebaseUnavailable _self;
  final $Res Function(NtsClockFault_TimebaseUnavailable) _then;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? kernReturn = null,Object? numer = null,Object? denom = null,}) {
  return _then(NtsClockFault_TimebaseUnavailable(
kernReturn: null == kernReturn ? _self.kernReturn : kernReturn // ignore: cast_nullable_to_non_nullable
as int,numer: null == numer ? _self.numer : numer // ignore: cast_nullable_to_non_nullable
as int,denom: null == denom ? _self.denom : denom // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class NtsClockFault_InvalidRaw extends NtsClockFault {
  const NtsClockFault_InvalidRaw(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault_InvalidRaw);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'NtsClockFault.invalidRaw()';
}


}




/// @nodoc


class NtsClockFault_ConversionOverflow extends NtsClockFault {
  const NtsClockFault_ConversionOverflow(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault_ConversionOverflow);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'NtsClockFault.conversionOverflow()';
}


}




/// @nodoc


class NtsClockFault_Regression extends NtsClockFault {
  const NtsClockFault_Regression({required this.previous, required this.observed}): super._();
  

 final  PlatformInt64 previous;
 final  PlatformInt64 observed;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsClockFault_RegressionCopyWith<NtsClockFault_Regression> get copyWith => _$NtsClockFault_RegressionCopyWithImpl<NtsClockFault_Regression>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault_Regression&&(identical(other.previous, previous) || other.previous == previous)&&(identical(other.observed, observed) || other.observed == observed));
}


@override
int get hashCode {
    return Object.hash(runtimeType,previous,observed);
}

@override
String toString() {
    return 'NtsClockFault.regression(previous: $previous, observed: $observed)';
}


}

/// @nodoc
abstract mixin class $NtsClockFault_RegressionCopyWith<$Res> implements $NtsClockFaultCopyWith<$Res> {
  factory $NtsClockFault_RegressionCopyWith(NtsClockFault_Regression value, $Res Function(NtsClockFault_Regression) _then) = _$NtsClockFault_RegressionCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 previous, PlatformInt64 observed
});




}
/// @nodoc
class _$NtsClockFault_RegressionCopyWithImpl<$Res>
    implements $NtsClockFault_RegressionCopyWith<$Res> {
  _$NtsClockFault_RegressionCopyWithImpl(this._self, this._then);

  final NtsClockFault_Regression _self;
  final $Res Function(NtsClockFault_Regression) _then;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? previous = null,Object? observed = null,}) {
  return _then(NtsClockFault_Regression(
previous: null == previous ? _self.previous : previous // ignore: cast_nullable_to_non_nullable
as PlatformInt64,observed: null == observed ? _self.observed : observed // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NtsClockFault_GenerationChanged extends NtsClockFault {
  const NtsClockFault_GenerationChanged({required this.expected, required this.observed}): super._();
  

 final  PlatformInt64 expected;
 final  PlatformInt64 observed;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsClockFault_GenerationChangedCopyWith<NtsClockFault_GenerationChanged> get copyWith => _$NtsClockFault_GenerationChangedCopyWithImpl<NtsClockFault_GenerationChanged>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault_GenerationChanged&&(identical(other.expected, expected) || other.expected == expected)&&(identical(other.observed, observed) || other.observed == observed));
}


@override
int get hashCode {
    return Object.hash(runtimeType,expected,observed);
}

@override
String toString() {
    return 'NtsClockFault.generationChanged(expected: $expected, observed: $observed)';
}


}

/// @nodoc
abstract mixin class $NtsClockFault_GenerationChangedCopyWith<$Res> implements $NtsClockFaultCopyWith<$Res> {
  factory $NtsClockFault_GenerationChangedCopyWith(NtsClockFault_GenerationChanged value, $Res Function(NtsClockFault_GenerationChanged) _then) = _$NtsClockFault_GenerationChangedCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 expected, PlatformInt64 observed
});




}
/// @nodoc
class _$NtsClockFault_GenerationChangedCopyWithImpl<$Res>
    implements $NtsClockFault_GenerationChangedCopyWith<$Res> {
  _$NtsClockFault_GenerationChangedCopyWithImpl(this._self, this._then);

  final NtsClockFault_GenerationChanged _self;
  final $Res Function(NtsClockFault_GenerationChanged) _then;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? expected = null,Object? observed = null,}) {
  return _then(NtsClockFault_GenerationChanged(
expected: null == expected ? _self.expected : expected // ignore: cast_nullable_to_non_nullable
as PlatformInt64,observed: null == observed ? _self.observed : observed // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class NtsClockFault_SuspendedInFlight extends NtsClockFault {
  const NtsClockFault_SuspendedInFlight({required this.boottimeMicros, required this.monotonicMicros}): super._();
  

 final  PlatformInt64 boottimeMicros;
 final  PlatformInt64 monotonicMicros;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsClockFault_SuspendedInFlightCopyWith<NtsClockFault_SuspendedInFlight> get copyWith => _$NtsClockFault_SuspendedInFlightCopyWithImpl<NtsClockFault_SuspendedInFlight>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsClockFault_SuspendedInFlight&&(identical(other.boottimeMicros, boottimeMicros) || other.boottimeMicros == boottimeMicros)&&(identical(other.monotonicMicros, monotonicMicros) || other.monotonicMicros == monotonicMicros));
}


@override
int get hashCode => Object.hash(runtimeType,boottimeMicros,monotonicMicros);

@override
String toString() {
  return 'NtsClockFault.suspendedInFlight(boottimeMicros: $boottimeMicros, monotonicMicros: $monotonicMicros)';
}


}

/// @nodoc
abstract mixin class $NtsClockFault_SuspendedInFlightCopyWith<$Res> implements $NtsClockFaultCopyWith<$Res> {
  factory $NtsClockFault_SuspendedInFlightCopyWith(NtsClockFault_SuspendedInFlight value, $Res Function(NtsClockFault_SuspendedInFlight) _then) = _$NtsClockFault_SuspendedInFlightCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 boottimeMicros, PlatformInt64 monotonicMicros
});




}
/// @nodoc
class _$NtsClockFault_SuspendedInFlightCopyWithImpl<$Res>
    implements $NtsClockFault_SuspendedInFlightCopyWith<$Res> {
  _$NtsClockFault_SuspendedInFlightCopyWithImpl(this._self, this._then);

  final NtsClockFault_SuspendedInFlight _self;
  final $Res Function(NtsClockFault_SuspendedInFlight) _then;

/// Create a copy of NtsClockFault
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? boottimeMicros = null,Object? monotonicMicros = null,}) {
  return _then(NtsClockFault_SuspendedInFlight(
boottimeMicros: null == boottimeMicros ? _self.boottimeMicros : boottimeMicros // ignore: cast_nullable_to_non_nullable
as PlatformInt64,monotonicMicros: null == monotonicMicros ? _self.monotonicMicros : monotonicMicros // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc
mixin _$NtsError {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'NtsError()';
}


}

/// @nodoc
class $NtsErrorCopyWith<$Res>  {
$NtsErrorCopyWith(NtsError _, $Res Function(NtsError) __);
}


/// Adds pattern-matching-related methods to [NtsError].
extension NtsErrorPatterns on NtsError {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( NtsError_InvalidSpec value)?  invalidSpec,TResult Function( NtsError_Network value)?  network,TResult Function( NtsError_KeProtocol value)?  keProtocol,TResult Function( NtsError_NtpProtocol value)?  ntpProtocol,TResult Function( NtsError_Authentication value)?  authentication,TResult Function( NtsError_Timeout value)?  timeout,TResult Function( NtsError_NoCookies value)?  noCookies,TResult Function( NtsError_TrustBackendUnavailable value)?  trustBackendUnavailable,TResult Function( NtsError_ClockFault value)?  clockFault,TResult Function( NtsError_Internal value)?  internal,required TResult orElse(),}){
final _that = this;
switch (_that) {
case NtsError_InvalidSpec() when invalidSpec != null:
return invalidSpec(_that);case NtsError_Network() when network != null:
return network(_that);case NtsError_KeProtocol() when keProtocol != null:
return keProtocol(_that);case NtsError_NtpProtocol() when ntpProtocol != null:
return ntpProtocol(_that);case NtsError_Authentication() when authentication != null:
return authentication(_that);case NtsError_Timeout() when timeout != null:
return timeout(_that);case NtsError_NoCookies() when noCookies != null:
return noCookies(_that);case NtsError_TrustBackendUnavailable() when trustBackendUnavailable != null:
return trustBackendUnavailable(_that);case NtsError_ClockFault() when clockFault != null:
return clockFault(_that);case NtsError_Internal() when internal != null:
return internal(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( NtsError_InvalidSpec value)  invalidSpec,required TResult Function( NtsError_Network value)  network,required TResult Function( NtsError_KeProtocol value)  keProtocol,required TResult Function( NtsError_NtpProtocol value)  ntpProtocol,required TResult Function( NtsError_Authentication value)  authentication,required TResult Function( NtsError_Timeout value)  timeout,required TResult Function( NtsError_NoCookies value)  noCookies,required TResult Function( NtsError_TrustBackendUnavailable value)  trustBackendUnavailable,required TResult Function( NtsError_ClockFault value)  clockFault,required TResult Function( NtsError_Internal value)  internal,}){
final _that = this;
switch (_that) {
case NtsError_InvalidSpec():
return invalidSpec(_that);case NtsError_Network():
return network(_that);case NtsError_KeProtocol():
return keProtocol(_that);case NtsError_NtpProtocol():
return ntpProtocol(_that);case NtsError_Authentication():
return authentication(_that);case NtsError_Timeout():
return timeout(_that);case NtsError_NoCookies():
return noCookies(_that);case NtsError_TrustBackendUnavailable():
return trustBackendUnavailable(_that);case NtsError_ClockFault():
return clockFault(_that);case NtsError_Internal():
return internal(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( NtsError_InvalidSpec value)?  invalidSpec,TResult? Function( NtsError_Network value)?  network,TResult? Function( NtsError_KeProtocol value)?  keProtocol,TResult? Function( NtsError_NtpProtocol value)?  ntpProtocol,TResult? Function( NtsError_Authentication value)?  authentication,TResult? Function( NtsError_Timeout value)?  timeout,TResult? Function( NtsError_NoCookies value)?  noCookies,TResult? Function( NtsError_TrustBackendUnavailable value)?  trustBackendUnavailable,TResult? Function( NtsError_ClockFault value)?  clockFault,TResult? Function( NtsError_Internal value)?  internal,}){
final _that = this;
switch (_that) {
case NtsError_InvalidSpec() when invalidSpec != null:
return invalidSpec(_that);case NtsError_Network() when network != null:
return network(_that);case NtsError_KeProtocol() when keProtocol != null:
return keProtocol(_that);case NtsError_NtpProtocol() when ntpProtocol != null:
return ntpProtocol(_that);case NtsError_Authentication() when authentication != null:
return authentication(_that);case NtsError_Timeout() when timeout != null:
return timeout(_that);case NtsError_NoCookies() when noCookies != null:
return noCookies(_that);case NtsError_TrustBackendUnavailable() when trustBackendUnavailable != null:
return trustBackendUnavailable(_that);case NtsError_ClockFault() when clockFault != null:
return clockFault(_that);case NtsError_Internal() when internal != null:
return internal(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field0)?  invalidSpec,TResult Function( String message,  TrustBackend? trustBackend)?  network,TResult Function( String message,  TrustBackend? trustBackend)?  keProtocol,TResult Function( String message,  TrustBackend? trustBackend)?  ntpProtocol,TResult Function( String message,  TrustBackend? trustBackend)?  authentication,TResult Function( TimeoutPhase phase,  TrustBackend? trustBackend)?  timeout,TResult Function( TrustBackend? trustBackend)?  noCookies,TResult Function( String field0)?  trustBackendUnavailable,TResult Function( ClockFaultStage stage,  NtsClockFault fault,  PlatformInt64 generation,  TrustBackend? trustBackend)?  clockFault,TResult Function( String field0)?  internal,required TResult orElse(),}) {final _that = this;
switch (_that) {
case NtsError_InvalidSpec() when invalidSpec != null:
return invalidSpec(_that.field0);case NtsError_Network() when network != null:
return network(_that.message,_that.trustBackend);case NtsError_KeProtocol() when keProtocol != null:
return keProtocol(_that.message,_that.trustBackend);case NtsError_NtpProtocol() when ntpProtocol != null:
return ntpProtocol(_that.message,_that.trustBackend);case NtsError_Authentication() when authentication != null:
return authentication(_that.message,_that.trustBackend);case NtsError_Timeout() when timeout != null:
return timeout(_that.phase,_that.trustBackend);case NtsError_NoCookies() when noCookies != null:
return noCookies(_that.trustBackend);case NtsError_TrustBackendUnavailable() when trustBackendUnavailable != null:
return trustBackendUnavailable(_that.field0);case NtsError_ClockFault() when clockFault != null:
return clockFault(_that.stage,_that.fault,_that.generation,_that.trustBackend);case NtsError_Internal() when internal != null:
return internal(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field0)  invalidSpec,required TResult Function( String message,  TrustBackend? trustBackend)  network,required TResult Function( String message,  TrustBackend? trustBackend)  keProtocol,required TResult Function( String message,  TrustBackend? trustBackend)  ntpProtocol,required TResult Function( String message,  TrustBackend? trustBackend)  authentication,required TResult Function( TimeoutPhase phase,  TrustBackend? trustBackend)  timeout,required TResult Function( TrustBackend? trustBackend)  noCookies,required TResult Function( String field0)  trustBackendUnavailable,required TResult Function( ClockFaultStage stage,  NtsClockFault fault,  PlatformInt64 generation,  TrustBackend? trustBackend)  clockFault,required TResult Function( String field0)  internal,}) {final _that = this;
switch (_that) {
case NtsError_InvalidSpec():
return invalidSpec(_that.field0);case NtsError_Network():
return network(_that.message,_that.trustBackend);case NtsError_KeProtocol():
return keProtocol(_that.message,_that.trustBackend);case NtsError_NtpProtocol():
return ntpProtocol(_that.message,_that.trustBackend);case NtsError_Authentication():
return authentication(_that.message,_that.trustBackend);case NtsError_Timeout():
return timeout(_that.phase,_that.trustBackend);case NtsError_NoCookies():
return noCookies(_that.trustBackend);case NtsError_TrustBackendUnavailable():
return trustBackendUnavailable(_that.field0);case NtsError_ClockFault():
return clockFault(_that.stage,_that.fault,_that.generation,_that.trustBackend);case NtsError_Internal():
return internal(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field0)?  invalidSpec,TResult? Function( String message,  TrustBackend? trustBackend)?  network,TResult? Function( String message,  TrustBackend? trustBackend)?  keProtocol,TResult? Function( String message,  TrustBackend? trustBackend)?  ntpProtocol,TResult? Function( String message,  TrustBackend? trustBackend)?  authentication,TResult? Function( TimeoutPhase phase,  TrustBackend? trustBackend)?  timeout,TResult? Function( TrustBackend? trustBackend)?  noCookies,TResult? Function( String field0)?  trustBackendUnavailable,TResult? Function( ClockFaultStage stage,  NtsClockFault fault,  PlatformInt64 generation,  TrustBackend? trustBackend)?  clockFault,TResult? Function( String field0)?  internal,}) {final _that = this;
switch (_that) {
case NtsError_InvalidSpec() when invalidSpec != null:
return invalidSpec(_that.field0);case NtsError_Network() when network != null:
return network(_that.message,_that.trustBackend);case NtsError_KeProtocol() when keProtocol != null:
return keProtocol(_that.message,_that.trustBackend);case NtsError_NtpProtocol() when ntpProtocol != null:
return ntpProtocol(_that.message,_that.trustBackend);case NtsError_Authentication() when authentication != null:
return authentication(_that.message,_that.trustBackend);case NtsError_Timeout() when timeout != null:
return timeout(_that.phase,_that.trustBackend);case NtsError_NoCookies() when noCookies != null:
return noCookies(_that.trustBackend);case NtsError_TrustBackendUnavailable() when trustBackendUnavailable != null:
return trustBackendUnavailable(_that.field0);case NtsError_ClockFault() when clockFault != null:
return clockFault(_that.stage,_that.fault,_that.generation,_that.trustBackend);case NtsError_Internal() when internal != null:
return internal(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class NtsError_InvalidSpec extends NtsError {
  const NtsError_InvalidSpec(this.field0): super._();
  

 final  String field0;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_InvalidSpecCopyWith<NtsError_InvalidSpec> get copyWith => _$NtsError_InvalidSpecCopyWithImpl<NtsError_InvalidSpec>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_InvalidSpec&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'NtsError.invalidSpec(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $NtsError_InvalidSpecCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_InvalidSpecCopyWith(NtsError_InvalidSpec value, $Res Function(NtsError_InvalidSpec) _then) = _$NtsError_InvalidSpecCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$NtsError_InvalidSpecCopyWithImpl<$Res>
    implements $NtsError_InvalidSpecCopyWith<$Res> {
  _$NtsError_InvalidSpecCopyWithImpl(this._self, this._then);

  final NtsError_InvalidSpec _self;
  final $Res Function(NtsError_InvalidSpec) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(NtsError_InvalidSpec(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NtsError_Network extends NtsError {
  const NtsError_Network({required this.message, this.trustBackend}): super._();
  

 final  String message;
 final  TrustBackend? trustBackend;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_NetworkCopyWith<NtsError_Network> get copyWith => _$NtsError_NetworkCopyWithImpl<NtsError_Network>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_Network&&(identical(other.message, message) || other.message == message)&&(identical(other.trustBackend, trustBackend) || other.trustBackend == trustBackend));
}


@override
int get hashCode {
    return Object.hash(runtimeType,message,trustBackend);
}

@override
String toString() {
    return 'NtsError.network(message: $message, trustBackend: $trustBackend)';
}


}

/// @nodoc
abstract mixin class $NtsError_NetworkCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_NetworkCopyWith(NtsError_Network value, $Res Function(NtsError_Network) _then) = _$NtsError_NetworkCopyWithImpl;
@useResult
$Res call({
 String message, TrustBackend? trustBackend
});




}
/// @nodoc
class _$NtsError_NetworkCopyWithImpl<$Res>
    implements $NtsError_NetworkCopyWith<$Res> {
  _$NtsError_NetworkCopyWithImpl(this._self, this._then);

  final NtsError_Network _self;
  final $Res Function(NtsError_Network) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,Object? trustBackend = freezed,}) {
  return _then(NtsError_Network(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,trustBackend: freezed == trustBackend ? _self.trustBackend : trustBackend // ignore: cast_nullable_to_non_nullable
as TrustBackend?,
  ));
}


}

/// @nodoc


class NtsError_KeProtocol extends NtsError {
  const NtsError_KeProtocol({required this.message, this.trustBackend}): super._();
  

 final  String message;
 final  TrustBackend? trustBackend;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_KeProtocolCopyWith<NtsError_KeProtocol> get copyWith => _$NtsError_KeProtocolCopyWithImpl<NtsError_KeProtocol>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_KeProtocol&&(identical(other.message, message) || other.message == message)&&(identical(other.trustBackend, trustBackend) || other.trustBackend == trustBackend));
}


@override
int get hashCode {
    return Object.hash(runtimeType,message,trustBackend);
}

@override
String toString() {
    return 'NtsError.keProtocol(message: $message, trustBackend: $trustBackend)';
}


}

/// @nodoc
abstract mixin class $NtsError_KeProtocolCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_KeProtocolCopyWith(NtsError_KeProtocol value, $Res Function(NtsError_KeProtocol) _then) = _$NtsError_KeProtocolCopyWithImpl;
@useResult
$Res call({
 String message, TrustBackend? trustBackend
});




}
/// @nodoc
class _$NtsError_KeProtocolCopyWithImpl<$Res>
    implements $NtsError_KeProtocolCopyWith<$Res> {
  _$NtsError_KeProtocolCopyWithImpl(this._self, this._then);

  final NtsError_KeProtocol _self;
  final $Res Function(NtsError_KeProtocol) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,Object? trustBackend = freezed,}) {
  return _then(NtsError_KeProtocol(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,trustBackend: freezed == trustBackend ? _self.trustBackend : trustBackend // ignore: cast_nullable_to_non_nullable
as TrustBackend?,
  ));
}


}

/// @nodoc


class NtsError_NtpProtocol extends NtsError {
  const NtsError_NtpProtocol({required this.message, this.trustBackend}): super._();
  

 final  String message;
 final  TrustBackend? trustBackend;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_NtpProtocolCopyWith<NtsError_NtpProtocol> get copyWith => _$NtsError_NtpProtocolCopyWithImpl<NtsError_NtpProtocol>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_NtpProtocol&&(identical(other.message, message) || other.message == message)&&(identical(other.trustBackend, trustBackend) || other.trustBackend == trustBackend));
}


@override
int get hashCode {
    return Object.hash(runtimeType,message,trustBackend);
}

@override
String toString() {
    return 'NtsError.ntpProtocol(message: $message, trustBackend: $trustBackend)';
}


}

/// @nodoc
abstract mixin class $NtsError_NtpProtocolCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_NtpProtocolCopyWith(NtsError_NtpProtocol value, $Res Function(NtsError_NtpProtocol) _then) = _$NtsError_NtpProtocolCopyWithImpl;
@useResult
$Res call({
 String message, TrustBackend? trustBackend
});




}
/// @nodoc
class _$NtsError_NtpProtocolCopyWithImpl<$Res>
    implements $NtsError_NtpProtocolCopyWith<$Res> {
  _$NtsError_NtpProtocolCopyWithImpl(this._self, this._then);

  final NtsError_NtpProtocol _self;
  final $Res Function(NtsError_NtpProtocol) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,Object? trustBackend = freezed,}) {
  return _then(NtsError_NtpProtocol(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,trustBackend: freezed == trustBackend ? _self.trustBackend : trustBackend // ignore: cast_nullable_to_non_nullable
as TrustBackend?,
  ));
}


}

/// @nodoc


class NtsError_Authentication extends NtsError {
  const NtsError_Authentication({required this.message, this.trustBackend}): super._();
  

 final  String message;
 final  TrustBackend? trustBackend;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_AuthenticationCopyWith<NtsError_Authentication> get copyWith => _$NtsError_AuthenticationCopyWithImpl<NtsError_Authentication>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_Authentication&&(identical(other.message, message) || other.message == message)&&(identical(other.trustBackend, trustBackend) || other.trustBackend == trustBackend));
}


@override
int get hashCode {
    return Object.hash(runtimeType,message,trustBackend);
}

@override
String toString() {
    return 'NtsError.authentication(message: $message, trustBackend: $trustBackend)';
}


}

/// @nodoc
abstract mixin class $NtsError_AuthenticationCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_AuthenticationCopyWith(NtsError_Authentication value, $Res Function(NtsError_Authentication) _then) = _$NtsError_AuthenticationCopyWithImpl;
@useResult
$Res call({
 String message, TrustBackend? trustBackend
});




}
/// @nodoc
class _$NtsError_AuthenticationCopyWithImpl<$Res>
    implements $NtsError_AuthenticationCopyWith<$Res> {
  _$NtsError_AuthenticationCopyWithImpl(this._self, this._then);

  final NtsError_Authentication _self;
  final $Res Function(NtsError_Authentication) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,Object? trustBackend = freezed,}) {
  return _then(NtsError_Authentication(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,trustBackend: freezed == trustBackend ? _self.trustBackend : trustBackend // ignore: cast_nullable_to_non_nullable
as TrustBackend?,
  ));
}


}

/// @nodoc


class NtsError_Timeout extends NtsError {
  const NtsError_Timeout({required this.phase, this.trustBackend}): super._();
  

 final  TimeoutPhase phase;
 final  TrustBackend? trustBackend;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_TimeoutCopyWith<NtsError_Timeout> get copyWith => _$NtsError_TimeoutCopyWithImpl<NtsError_Timeout>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_Timeout&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.trustBackend, trustBackend) || other.trustBackend == trustBackend));
}


@override
int get hashCode {
    return Object.hash(runtimeType,phase,trustBackend);
}

@override
String toString() {
    return 'NtsError.timeout(phase: $phase, trustBackend: $trustBackend)';
}


}

/// @nodoc
abstract mixin class $NtsError_TimeoutCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_TimeoutCopyWith(NtsError_Timeout value, $Res Function(NtsError_Timeout) _then) = _$NtsError_TimeoutCopyWithImpl;
@useResult
$Res call({
 TimeoutPhase phase, TrustBackend? trustBackend
});




}
/// @nodoc
class _$NtsError_TimeoutCopyWithImpl<$Res>
    implements $NtsError_TimeoutCopyWith<$Res> {
  _$NtsError_TimeoutCopyWithImpl(this._self, this._then);

  final NtsError_Timeout _self;
  final $Res Function(NtsError_Timeout) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? phase = null,Object? trustBackend = freezed,}) {
  return _then(NtsError_Timeout(
phase: null == phase ? _self.phase : phase // ignore: cast_nullable_to_non_nullable
as TimeoutPhase,trustBackend: freezed == trustBackend ? _self.trustBackend : trustBackend // ignore: cast_nullable_to_non_nullable
as TrustBackend?,
  ));
}


}

/// @nodoc


class NtsError_NoCookies extends NtsError {
  const NtsError_NoCookies({this.trustBackend}): super._();
  

 final  TrustBackend? trustBackend;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_NoCookiesCopyWith<NtsError_NoCookies> get copyWith => _$NtsError_NoCookiesCopyWithImpl<NtsError_NoCookies>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_NoCookies&&(identical(other.trustBackend, trustBackend) || other.trustBackend == trustBackend));
}


@override
int get hashCode {
    return Object.hash(runtimeType,trustBackend);
}

@override
String toString() {
    return 'NtsError.noCookies(trustBackend: $trustBackend)';
}


}

/// @nodoc
abstract mixin class $NtsError_NoCookiesCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_NoCookiesCopyWith(NtsError_NoCookies value, $Res Function(NtsError_NoCookies) _then) = _$NtsError_NoCookiesCopyWithImpl;
@useResult
$Res call({
 TrustBackend? trustBackend
});




}
/// @nodoc
class _$NtsError_NoCookiesCopyWithImpl<$Res>
    implements $NtsError_NoCookiesCopyWith<$Res> {
  _$NtsError_NoCookiesCopyWithImpl(this._self, this._then);

  final NtsError_NoCookies _self;
  final $Res Function(NtsError_NoCookies) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? trustBackend = freezed,}) {
  return _then(NtsError_NoCookies(
trustBackend: freezed == trustBackend ? _self.trustBackend : trustBackend // ignore: cast_nullable_to_non_nullable
as TrustBackend?,
  ));
}


}

/// @nodoc


class NtsError_TrustBackendUnavailable extends NtsError {
  const NtsError_TrustBackendUnavailable(this.field0): super._();
  

 final  String field0;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_TrustBackendUnavailableCopyWith<NtsError_TrustBackendUnavailable> get copyWith => _$NtsError_TrustBackendUnavailableCopyWithImpl<NtsError_TrustBackendUnavailable>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_TrustBackendUnavailable&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'NtsError.trustBackendUnavailable(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $NtsError_TrustBackendUnavailableCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_TrustBackendUnavailableCopyWith(NtsError_TrustBackendUnavailable value, $Res Function(NtsError_TrustBackendUnavailable) _then) = _$NtsError_TrustBackendUnavailableCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$NtsError_TrustBackendUnavailableCopyWithImpl<$Res>
    implements $NtsError_TrustBackendUnavailableCopyWith<$Res> {
  _$NtsError_TrustBackendUnavailableCopyWithImpl(this._self, this._then);

  final NtsError_TrustBackendUnavailable _self;
  final $Res Function(NtsError_TrustBackendUnavailable) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(NtsError_TrustBackendUnavailable(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NtsError_ClockFault extends NtsError {
  const NtsError_ClockFault({required this.stage, required this.fault, required this.generation, this.trustBackend}): super._();
  

 final  ClockFaultStage stage;
 final  NtsClockFault fault;
 final  PlatformInt64 generation;
 final  TrustBackend? trustBackend;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_ClockFaultCopyWith<NtsError_ClockFault> get copyWith => _$NtsError_ClockFaultCopyWithImpl<NtsError_ClockFault>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_ClockFault&&(identical(other.stage, stage) || other.stage == stage)&&(identical(other.fault, fault) || other.fault == fault)&&(identical(other.generation, generation) || other.generation == generation)&&(identical(other.trustBackend, trustBackend) || other.trustBackend == trustBackend));
}


@override
int get hashCode => Object.hash(runtimeType,stage,fault,generation,trustBackend);

@override
String toString() {
  return 'NtsError.clockFault(stage: $stage, fault: $fault, generation: $generation, trustBackend: $trustBackend)';
}


}

/// @nodoc
abstract mixin class $NtsError_ClockFaultCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_ClockFaultCopyWith(NtsError_ClockFault value, $Res Function(NtsError_ClockFault) _then) = _$NtsError_ClockFaultCopyWithImpl;
@useResult
$Res call({
 ClockFaultStage stage, NtsClockFault fault, PlatformInt64 generation, TrustBackend? trustBackend
});


$NtsClockFaultCopyWith<$Res> get fault;

}
/// @nodoc
class _$NtsError_ClockFaultCopyWithImpl<$Res>
    implements $NtsError_ClockFaultCopyWith<$Res> {
  _$NtsError_ClockFaultCopyWithImpl(this._self, this._then);

  final NtsError_ClockFault _self;
  final $Res Function(NtsError_ClockFault) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? stage = null,Object? fault = null,Object? generation = null,Object? trustBackend = freezed,}) {
  return _then(NtsError_ClockFault(
stage: null == stage ? _self.stage : stage // ignore: cast_nullable_to_non_nullable
as ClockFaultStage,fault: null == fault ? _self.fault : fault // ignore: cast_nullable_to_non_nullable
as NtsClockFault,generation: null == generation ? _self.generation : generation // ignore: cast_nullable_to_non_nullable
as PlatformInt64,trustBackend: freezed == trustBackend ? _self.trustBackend : trustBackend // ignore: cast_nullable_to_non_nullable
as TrustBackend?,
  ));
}

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$NtsClockFaultCopyWith<$Res> get fault {
  
  return $NtsClockFaultCopyWith<$Res>(_self.fault, (value) {
    return _then(_self.copyWith(fault: value));
  });
}
}

/// @nodoc


class NtsError_Internal extends NtsError {
  const NtsError_Internal(this.field0): super._();
  

 final  String field0;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_InternalCopyWith<NtsError_Internal> get copyWith => _$NtsError_InternalCopyWithImpl<NtsError_Internal>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_Internal&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'NtsError.internal(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $NtsError_InternalCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_InternalCopyWith(NtsError_Internal value, $Res Function(NtsError_Internal) _then) = _$NtsError_InternalCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$NtsError_InternalCopyWithImpl<$Res>
    implements $NtsError_InternalCopyWith<$Res> {
  _$NtsError_InternalCopyWithImpl(this._self, this._then);

  final NtsError_Internal _self;
  final $Res Function(NtsError_Internal) _then;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(NtsError_Internal(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$TrustMode {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TrustMode);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TrustMode()';
}


}

/// @nodoc
class $TrustModeCopyWith<$Res>  {
$TrustModeCopyWith(TrustMode _, $Res Function(TrustMode) __);
}


/// Adds pattern-matching-related methods to [TrustMode].
extension TrustModePatterns on TrustMode {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( TrustMode_PlatformWithFallback value)?  platformWithFallback,TResult Function( TrustMode_PlatformOnly value)?  platformOnly,TResult Function( TrustMode_BundledOnly value)?  bundledOnly,TResult Function( TrustMode_Custom value)?  custom,required TResult orElse(),}){
final _that = this;
switch (_that) {
case TrustMode_PlatformWithFallback() when platformWithFallback != null:
return platformWithFallback(_that);case TrustMode_PlatformOnly() when platformOnly != null:
return platformOnly(_that);case TrustMode_BundledOnly() when bundledOnly != null:
return bundledOnly(_that);case TrustMode_Custom() when custom != null:
return custom(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( TrustMode_PlatformWithFallback value)  platformWithFallback,required TResult Function( TrustMode_PlatformOnly value)  platformOnly,required TResult Function( TrustMode_BundledOnly value)  bundledOnly,required TResult Function( TrustMode_Custom value)  custom,}){
final _that = this;
switch (_that) {
case TrustMode_PlatformWithFallback():
return platformWithFallback(_that);case TrustMode_PlatformOnly():
return platformOnly(_that);case TrustMode_BundledOnly():
return bundledOnly(_that);case TrustMode_Custom():
return custom(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( TrustMode_PlatformWithFallback value)?  platformWithFallback,TResult? Function( TrustMode_PlatformOnly value)?  platformOnly,TResult? Function( TrustMode_BundledOnly value)?  bundledOnly,TResult? Function( TrustMode_Custom value)?  custom,}){
final _that = this;
switch (_that) {
case TrustMode_PlatformWithFallback() when platformWithFallback != null:
return platformWithFallback(_that);case TrustMode_PlatformOnly() when platformOnly != null:
return platformOnly(_that);case TrustMode_BundledOnly() when bundledOnly != null:
return bundledOnly(_that);case TrustMode_Custom() when custom != null:
return custom(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  platformWithFallback,TResult Function()?  platformOnly,TResult Function()?  bundledOnly,TResult Function( Uint8List field0)?  custom,required TResult orElse(),}) {final _that = this;
switch (_that) {
case TrustMode_PlatformWithFallback() when platformWithFallback != null:
return platformWithFallback();case TrustMode_PlatformOnly() when platformOnly != null:
return platformOnly();case TrustMode_BundledOnly() when bundledOnly != null:
return bundledOnly();case TrustMode_Custom() when custom != null:
return custom(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  platformWithFallback,required TResult Function()  platformOnly,required TResult Function()  bundledOnly,required TResult Function( Uint8List field0)  custom,}) {final _that = this;
switch (_that) {
case TrustMode_PlatformWithFallback():
return platformWithFallback();case TrustMode_PlatformOnly():
return platformOnly();case TrustMode_BundledOnly():
return bundledOnly();case TrustMode_Custom():
return custom(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  platformWithFallback,TResult? Function()?  platformOnly,TResult? Function()?  bundledOnly,TResult? Function( Uint8List field0)?  custom,}) {final _that = this;
switch (_that) {
case TrustMode_PlatformWithFallback() when platformWithFallback != null:
return platformWithFallback();case TrustMode_PlatformOnly() when platformOnly != null:
return platformOnly();case TrustMode_BundledOnly() when bundledOnly != null:
return bundledOnly();case TrustMode_Custom() when custom != null:
return custom(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class TrustMode_PlatformWithFallback extends TrustMode {
  const TrustMode_PlatformWithFallback(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TrustMode_PlatformWithFallback);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TrustMode.platformWithFallback()';
}


}




/// @nodoc


class TrustMode_PlatformOnly extends TrustMode {
  const TrustMode_PlatformOnly(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TrustMode_PlatformOnly);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TrustMode.platformOnly()';
}


}




/// @nodoc


class TrustMode_BundledOnly extends TrustMode {
  const TrustMode_BundledOnly(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TrustMode_BundledOnly);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TrustMode.bundledOnly()';
}


}




/// @nodoc


class TrustMode_Custom extends TrustMode {
  const TrustMode_Custom(this.field0): super._();
  

 final  Uint8List field0;

/// Create a copy of TrustMode
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TrustMode_CustomCopyWith<TrustMode_Custom> get copyWith => _$TrustMode_CustomCopyWithImpl<TrustMode_Custom>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TrustMode_Custom&&const DeepCollectionEquality().equals(other.field0, field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(field0));
}

@override
String toString() {
    return 'TrustMode.custom(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $TrustMode_CustomCopyWith<$Res> implements $TrustModeCopyWith<$Res> {
  factory $TrustMode_CustomCopyWith(TrustMode_Custom value, $Res Function(TrustMode_Custom) _then) = _$TrustMode_CustomCopyWithImpl;
@useResult
$Res call({
 Uint8List field0
});




}
/// @nodoc
class _$TrustMode_CustomCopyWithImpl<$Res>
    implements $TrustMode_CustomCopyWith<$Res> {
  _$TrustMode_CustomCopyWithImpl(this._self, this._then);

  final TrustMode_Custom _self;
  final $Res Function(TrustMode_Custom) _then;

/// Create a copy of TrustMode
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(TrustMode_Custom(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

// dart format on
