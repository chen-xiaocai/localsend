// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'crop_state.dart';

class CropStateMapper extends ClassMapperBase<CropState> {
  CropStateMapper._();

  static CropStateMapper? _instance;
  static CropStateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CropStateMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'CropState';

  static double _$left(CropState v) => v.left;
  static const Field<CropState, double> _f$left = Field('left', _$left);
  static double _$top(CropState v) => v.top;
  static const Field<CropState, double> _f$top = Field('top', _$top);
  static double _$right(CropState v) => v.right;
  static const Field<CropState, double> _f$right = Field('right', _$right);
  static double _$bottom(CropState v) => v.bottom;
  static const Field<CropState, double> _f$bottom = Field('bottom', _$bottom);
  static int _$quarterTurns(CropState v) => v.quarterTurns;
  static const Field<CropState, int> _f$quarterTurns = Field(
    'quarterTurns',
    _$quarterTurns,
  );

  @override
  final MappableFields<CropState> fields = const {
    #left: _f$left,
    #top: _f$top,
    #right: _f$right,
    #bottom: _f$bottom,
    #quarterTurns: _f$quarterTurns,
  };

  static CropState _instantiate(DecodingData data) {
    return CropState(
      left: data.dec(_f$left),
      top: data.dec(_f$top),
      right: data.dec(_f$right),
      bottom: data.dec(_f$bottom),
      quarterTurns: data.dec(_f$quarterTurns),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static CropState fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CropState>(map);
  }

  static CropState deserialize(String json) {
    return ensureInitialized().decodeJson<CropState>(json);
  }
}

mixin CropStateMappable {
  String serialize() {
    return CropStateMapper.ensureInitialized().encodeJson<CropState>(
      this as CropState,
    );
  }

  Map<String, dynamic> toJson() {
    return CropStateMapper.ensureInitialized().encodeMap<CropState>(
      this as CropState,
    );
  }

  CropStateCopyWith<CropState, CropState, CropState> get copyWith =>
      _CropStateCopyWithImpl<CropState, CropState>(
        this as CropState,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return CropStateMapper.ensureInitialized().stringifyValue(
      this as CropState,
    );
  }

  @override
  bool operator ==(Object other) {
    return CropStateMapper.ensureInitialized().equalsValue(
      this as CropState,
      other,
    );
  }

  @override
  int get hashCode {
    return CropStateMapper.ensureInitialized().hashValue(this as CropState);
  }
}

extension CropStateValueCopy<$R, $Out> on ObjectCopyWith<$R, CropState, $Out> {
  CropStateCopyWith<$R, CropState, $Out> get $asCropState =>
      $base.as((v, t, t2) => _CropStateCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class CropStateCopyWith<$R, $In extends CropState, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    double? left,
    double? top,
    double? right,
    double? bottom,
    int? quarterTurns,
  });
  CropStateCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _CropStateCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, CropState, $Out>
    implements CropStateCopyWith<$R, CropState, $Out> {
  _CropStateCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<CropState> $mapper =
      CropStateMapper.ensureInitialized();
  @override
  $R call({
    double? left,
    double? top,
    double? right,
    double? bottom,
    int? quarterTurns,
  }) => $apply(
    FieldCopyWithData({
      if (left != null) #left: left,
      if (top != null) #top: top,
      if (right != null) #right: right,
      if (bottom != null) #bottom: bottom,
      if (quarterTurns != null) #quarterTurns: quarterTurns,
    }),
  );
  @override
  CropState $make(CopyWithData data) => CropState(
    left: data.get(#left, or: $value.left),
    top: data.get(#top, or: $value.top),
    right: data.get(#right, or: $value.right),
    bottom: data.get(#bottom, or: $value.bottom),
    quarterTurns: data.get(#quarterTurns, or: $value.quarterTurns),
  );

  @override
  CropStateCopyWith<$R2, CropState, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _CropStateCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

