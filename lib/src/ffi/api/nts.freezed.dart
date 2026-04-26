// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'nts.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( NtsError_InvalidSpec value)?  invalidSpec,TResult Function( NtsError_Network value)?  network,TResult Function( NtsError_KeProtocol value)?  keProtocol,TResult Function( NtsError_NtpProtocol value)?  ntpProtocol,TResult Function( NtsError_Authentication value)?  authentication,TResult Function( NtsError_Timeout value)?  timeout,TResult Function( NtsError_NoCookies value)?  noCookies,TResult Function( NtsError_Internal value)?  internal,required TResult orElse(),}){
final _that = this;
switch (_that) {
case NtsError_InvalidSpec() when invalidSpec != null:
return invalidSpec(_that);case NtsError_Network() when network != null:
return network(_that);case NtsError_KeProtocol() when keProtocol != null:
return keProtocol(_that);case NtsError_NtpProtocol() when ntpProtocol != null:
return ntpProtocol(_that);case NtsError_Authentication() when authentication != null:
return authentication(_that);case NtsError_Timeout() when timeout != null:
return timeout(_that);case NtsError_NoCookies() when noCookies != null:
return noCookies(_that);case NtsError_Internal() when internal != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( NtsError_InvalidSpec value)  invalidSpec,required TResult Function( NtsError_Network value)  network,required TResult Function( NtsError_KeProtocol value)  keProtocol,required TResult Function( NtsError_NtpProtocol value)  ntpProtocol,required TResult Function( NtsError_Authentication value)  authentication,required TResult Function( NtsError_Timeout value)  timeout,required TResult Function( NtsError_NoCookies value)  noCookies,required TResult Function( NtsError_Internal value)  internal,}){
final _that = this;
switch (_that) {
case NtsError_InvalidSpec():
return invalidSpec(_that);case NtsError_Network():
return network(_that);case NtsError_KeProtocol():
return keProtocol(_that);case NtsError_NtpProtocol():
return ntpProtocol(_that);case NtsError_Authentication():
return authentication(_that);case NtsError_Timeout():
return timeout(_that);case NtsError_NoCookies():
return noCookies(_that);case NtsError_Internal():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( NtsError_InvalidSpec value)?  invalidSpec,TResult? Function( NtsError_Network value)?  network,TResult? Function( NtsError_KeProtocol value)?  keProtocol,TResult? Function( NtsError_NtpProtocol value)?  ntpProtocol,TResult? Function( NtsError_Authentication value)?  authentication,TResult? Function( NtsError_Timeout value)?  timeout,TResult? Function( NtsError_NoCookies value)?  noCookies,TResult? Function( NtsError_Internal value)?  internal,}){
final _that = this;
switch (_that) {
case NtsError_InvalidSpec() when invalidSpec != null:
return invalidSpec(_that);case NtsError_Network() when network != null:
return network(_that);case NtsError_KeProtocol() when keProtocol != null:
return keProtocol(_that);case NtsError_NtpProtocol() when ntpProtocol != null:
return ntpProtocol(_that);case NtsError_Authentication() when authentication != null:
return authentication(_that);case NtsError_Timeout() when timeout != null:
return timeout(_that);case NtsError_NoCookies() when noCookies != null:
return noCookies(_that);case NtsError_Internal() when internal != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field0)?  invalidSpec,TResult Function( String field0)?  network,TResult Function( String field0)?  keProtocol,TResult Function( String field0)?  ntpProtocol,TResult Function( String field0)?  authentication,TResult Function()?  timeout,TResult Function()?  noCookies,TResult Function( String field0)?  internal,required TResult orElse(),}) {final _that = this;
switch (_that) {
case NtsError_InvalidSpec() when invalidSpec != null:
return invalidSpec(_that.field0);case NtsError_Network() when network != null:
return network(_that.field0);case NtsError_KeProtocol() when keProtocol != null:
return keProtocol(_that.field0);case NtsError_NtpProtocol() when ntpProtocol != null:
return ntpProtocol(_that.field0);case NtsError_Authentication() when authentication != null:
return authentication(_that.field0);case NtsError_Timeout() when timeout != null:
return timeout();case NtsError_NoCookies() when noCookies != null:
return noCookies();case NtsError_Internal() when internal != null:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field0)  invalidSpec,required TResult Function( String field0)  network,required TResult Function( String field0)  keProtocol,required TResult Function( String field0)  ntpProtocol,required TResult Function( String field0)  authentication,required TResult Function()  timeout,required TResult Function()  noCookies,required TResult Function( String field0)  internal,}) {final _that = this;
switch (_that) {
case NtsError_InvalidSpec():
return invalidSpec(_that.field0);case NtsError_Network():
return network(_that.field0);case NtsError_KeProtocol():
return keProtocol(_that.field0);case NtsError_NtpProtocol():
return ntpProtocol(_that.field0);case NtsError_Authentication():
return authentication(_that.field0);case NtsError_Timeout():
return timeout();case NtsError_NoCookies():
return noCookies();case NtsError_Internal():
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field0)?  invalidSpec,TResult? Function( String field0)?  network,TResult? Function( String field0)?  keProtocol,TResult? Function( String field0)?  ntpProtocol,TResult? Function( String field0)?  authentication,TResult? Function()?  timeout,TResult? Function()?  noCookies,TResult? Function( String field0)?  internal,}) {final _that = this;
switch (_that) {
case NtsError_InvalidSpec() when invalidSpec != null:
return invalidSpec(_that.field0);case NtsError_Network() when network != null:
return network(_that.field0);case NtsError_KeProtocol() when keProtocol != null:
return keProtocol(_that.field0);case NtsError_NtpProtocol() when ntpProtocol != null:
return ntpProtocol(_that.field0);case NtsError_Authentication() when authentication != null:
return authentication(_that.field0);case NtsError_Timeout() when timeout != null:
return timeout();case NtsError_NoCookies() when noCookies != null:
return noCookies();case NtsError_Internal() when internal != null:
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
int get hashCode => Object.hash(runtimeType,field0);

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
  const NtsError_Network(this.field0): super._();
  

 final  String field0;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_NetworkCopyWith<NtsError_Network> get copyWith => _$NtsError_NetworkCopyWithImpl<NtsError_Network>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_Network&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'NtsError.network(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $NtsError_NetworkCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_NetworkCopyWith(NtsError_Network value, $Res Function(NtsError_Network) _then) = _$NtsError_NetworkCopyWithImpl;
@useResult
$Res call({
 String field0
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
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(NtsError_Network(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NtsError_KeProtocol extends NtsError {
  const NtsError_KeProtocol(this.field0): super._();
  

 final  String field0;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_KeProtocolCopyWith<NtsError_KeProtocol> get copyWith => _$NtsError_KeProtocolCopyWithImpl<NtsError_KeProtocol>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_KeProtocol&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'NtsError.keProtocol(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $NtsError_KeProtocolCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_KeProtocolCopyWith(NtsError_KeProtocol value, $Res Function(NtsError_KeProtocol) _then) = _$NtsError_KeProtocolCopyWithImpl;
@useResult
$Res call({
 String field0
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
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(NtsError_KeProtocol(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NtsError_NtpProtocol extends NtsError {
  const NtsError_NtpProtocol(this.field0): super._();
  

 final  String field0;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_NtpProtocolCopyWith<NtsError_NtpProtocol> get copyWith => _$NtsError_NtpProtocolCopyWithImpl<NtsError_NtpProtocol>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_NtpProtocol&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'NtsError.ntpProtocol(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $NtsError_NtpProtocolCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_NtpProtocolCopyWith(NtsError_NtpProtocol value, $Res Function(NtsError_NtpProtocol) _then) = _$NtsError_NtpProtocolCopyWithImpl;
@useResult
$Res call({
 String field0
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
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(NtsError_NtpProtocol(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NtsError_Authentication extends NtsError {
  const NtsError_Authentication(this.field0): super._();
  

 final  String field0;

/// Create a copy of NtsError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NtsError_AuthenticationCopyWith<NtsError_Authentication> get copyWith => _$NtsError_AuthenticationCopyWithImpl<NtsError_Authentication>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_Authentication&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'NtsError.authentication(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $NtsError_AuthenticationCopyWith<$Res> implements $NtsErrorCopyWith<$Res> {
  factory $NtsError_AuthenticationCopyWith(NtsError_Authentication value, $Res Function(NtsError_Authentication) _then) = _$NtsError_AuthenticationCopyWithImpl;
@useResult
$Res call({
 String field0
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
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(NtsError_Authentication(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class NtsError_Timeout extends NtsError {
  const NtsError_Timeout(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_Timeout);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'NtsError.timeout()';
}


}




/// @nodoc


class NtsError_NoCookies extends NtsError {
  const NtsError_NoCookies(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NtsError_NoCookies);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'NtsError.noCookies()';
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
int get hashCode => Object.hash(runtimeType,field0);

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

// dart format on
