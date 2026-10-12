// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'ssh_access.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SshAccessState {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SshAccessState);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SshAccessState()';
}


}

/// @nodoc
class $SshAccessStateCopyWith<$Res>  {
$SshAccessStateCopyWith(SshAccessState _, $Res Function(SshAccessState) __);
}


/// Adds pattern-matching-related methods to [SshAccessState].
extension SshAccessStatePatterns on SshAccessState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SshAccessState_Ready value)?  ready,TResult Function( SshAccessState_NeedsProvisioning value)?  needsProvisioning,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SshAccessState_Ready() when ready != null:
return ready(_that);case SshAccessState_NeedsProvisioning() when needsProvisioning != null:
return needsProvisioning(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SshAccessState_Ready value)  ready,required TResult Function( SshAccessState_NeedsProvisioning value)  needsProvisioning,}){
final _that = this;
switch (_that) {
case SshAccessState_Ready():
return ready(_that);case SshAccessState_NeedsProvisioning():
return needsProvisioning(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SshAccessState_Ready value)?  ready,TResult? Function( SshAccessState_NeedsProvisioning value)?  needsProvisioning,}){
final _that = this;
switch (_that) {
case SshAccessState_Ready() when ready != null:
return ready(_that);case SshAccessState_NeedsProvisioning() when needsProvisioning != null:
return needsProvisioning(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( SshCredential credential)?  ready,TResult Function( String username,  ProvisionMethod method,  String keyFingerprint)?  needsProvisioning,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SshAccessState_Ready() when ready != null:
return ready(_that.credential);case SshAccessState_NeedsProvisioning() when needsProvisioning != null:
return needsProvisioning(_that.username,_that.method,_that.keyFingerprint);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( SshCredential credential)  ready,required TResult Function( String username,  ProvisionMethod method,  String keyFingerprint)  needsProvisioning,}) {final _that = this;
switch (_that) {
case SshAccessState_Ready():
return ready(_that.credential);case SshAccessState_NeedsProvisioning():
return needsProvisioning(_that.username,_that.method,_that.keyFingerprint);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( SshCredential credential)?  ready,TResult? Function( String username,  ProvisionMethod method,  String keyFingerprint)?  needsProvisioning,}) {final _that = this;
switch (_that) {
case SshAccessState_Ready() when ready != null:
return ready(_that.credential);case SshAccessState_NeedsProvisioning() when needsProvisioning != null:
return needsProvisioning(_that.username,_that.method,_that.keyFingerprint);case _:
  return null;

}
}

}

/// @nodoc


class SshAccessState_Ready extends SshAccessState {
  const SshAccessState_Ready({required this.credential}): super._();
  

 final  SshCredential credential;

/// Create a copy of SshAccessState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SshAccessState_ReadyCopyWith<SshAccessState_Ready> get copyWith => _$SshAccessState_ReadyCopyWithImpl<SshAccessState_Ready>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SshAccessState_Ready&&(identical(other.credential, credential) || other.credential == credential));
}


@override
int get hashCode => Object.hash(runtimeType,credential);

@override
String toString() {
  return 'SshAccessState.ready(credential: $credential)';
}


}

/// @nodoc
abstract mixin class $SshAccessState_ReadyCopyWith<$Res> implements $SshAccessStateCopyWith<$Res> {
  factory $SshAccessState_ReadyCopyWith(SshAccessState_Ready value, $Res Function(SshAccessState_Ready) _then) = _$SshAccessState_ReadyCopyWithImpl;
@useResult
$Res call({
 SshCredential credential
});




}
/// @nodoc
class _$SshAccessState_ReadyCopyWithImpl<$Res>
    implements $SshAccessState_ReadyCopyWith<$Res> {
  _$SshAccessState_ReadyCopyWithImpl(this._self, this._then);

  final SshAccessState_Ready _self;
  final $Res Function(SshAccessState_Ready) _then;

/// Create a copy of SshAccessState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? credential = null,}) {
  return _then(SshAccessState_Ready(
credential: null == credential ? _self.credential : credential // ignore: cast_nullable_to_non_nullable
as SshCredential,
  ));
}


}

/// @nodoc


class SshAccessState_NeedsProvisioning extends SshAccessState {
  const SshAccessState_NeedsProvisioning({required this.username, required this.method, required this.keyFingerprint}): super._();
  

 final  String username;
 final  ProvisionMethod method;
 final  String keyFingerprint;

/// Create a copy of SshAccessState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SshAccessState_NeedsProvisioningCopyWith<SshAccessState_NeedsProvisioning> get copyWith => _$SshAccessState_NeedsProvisioningCopyWithImpl<SshAccessState_NeedsProvisioning>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SshAccessState_NeedsProvisioning&&(identical(other.username, username) || other.username == username)&&(identical(other.method, method) || other.method == method)&&(identical(other.keyFingerprint, keyFingerprint) || other.keyFingerprint == keyFingerprint));
}


@override
int get hashCode => Object.hash(runtimeType,username,method,keyFingerprint);

@override
String toString() {
  return 'SshAccessState.needsProvisioning(username: $username, method: $method, keyFingerprint: $keyFingerprint)';
}


}

/// @nodoc
abstract mixin class $SshAccessState_NeedsProvisioningCopyWith<$Res> implements $SshAccessStateCopyWith<$Res> {
  factory $SshAccessState_NeedsProvisioningCopyWith(SshAccessState_NeedsProvisioning value, $Res Function(SshAccessState_NeedsProvisioning) _then) = _$SshAccessState_NeedsProvisioningCopyWithImpl;
@useResult
$Res call({
 String username, ProvisionMethod method, String keyFingerprint
});




}
/// @nodoc
class _$SshAccessState_NeedsProvisioningCopyWithImpl<$Res>
    implements $SshAccessState_NeedsProvisioningCopyWith<$Res> {
  _$SshAccessState_NeedsProvisioningCopyWithImpl(this._self, this._then);

  final SshAccessState_NeedsProvisioning _self;
  final $Res Function(SshAccessState_NeedsProvisioning) _then;

/// Create a copy of SshAccessState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? username = null,Object? method = null,Object? keyFingerprint = null,}) {
  return _then(SshAccessState_NeedsProvisioning(
username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,method: null == method ? _self.method : method // ignore: cast_nullable_to_non_nullable
as ProvisionMethod,keyFingerprint: null == keyFingerprint ? _self.keyFingerprint : keyFingerprint // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
