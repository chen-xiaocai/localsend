import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:convert/convert.dart';

/// LocalSend 安全上下文：RSA 私钥 + 自签证书 + 证书指纹。
///
/// 移植自 app/lib/util/security_helper.dart，去掉 Rust 依赖，
/// 纯 basic_utils 实现，可在无 GUI 的 CLI 中独立运行。
class SecurityContextData {
  final String privateKey;
  final String publicKey;
  final String certificate;
  final String certificateHash;

  const SecurityContextData({
    required this.privateKey,
    required this.publicKey,
    required this.certificate,
    required this.certificateHash,
  });

  Map<String, dynamic> toJson() => {
        'privateKey': privateKey,
        'publicKey': publicKey,
        'certificate': certificate,
        'certificateHash': certificateHash,
      };

  factory SecurityContextData.fromJson(Map<String, dynamic> json) =>
      SecurityContextData(
        privateKey: json['privateKey'] as String,
        publicKey: json['publicKey'] as String,
        certificate: json['certificate'] as String,
        certificateHash: json['certificateHash'] as String,
      );
}

/// 生成新的 [SecurityContextData]（RSA 2048 + 自签证书，有效期 10 年）。
SecurityContextData generateSecurityContext() {
  final keyPair = CryptoUtils.generateRSAKeyPair();
  final privateKey = keyPair.privateKey as RSAPrivateKey;
  final publicKey = keyPair.publicKey as RSAPublicKey;
  final dn = {
    'CN': 'LocalSend User',
    'O': '',
    'OU': '',
    'L': '',
    'S': '',
    'C': '',
  };
  final csr = X509Utils.generateRsaCsrPem(dn, privateKey, publicKey);
  final certificate = X509Utils.generateSelfSignedCertificate(
    keyPair.privateKey,
    csr,
    365 * 10,
  );
  final hash = calculateHashOfCertificate(certificate);
  final spki = extractPublicKeyFromCertificate(certificate);
  return SecurityContextData(
    privateKey: CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(privateKey),
    publicKey: spki,
    certificate: certificate,
    certificateHash: hash,
  );
}

/// 计算证书指纹：PEM -> DER -> SHA-256。
String calculateHashOfCertificate(String certificate) {
  final pemContent = certificate
      .replaceAll('\r\n', '\n')
      .split('\n')
      .where((line) => line.isNotEmpty && !line.startsWith('---'))
      .join();
  final der = base64Decode(pemContent);
  return CryptoUtils.getHash(
    Uint8List.fromList(der),
    algorithmName: 'SHA-256',
  );
}

/// 从证书中提取 SPKI 公钥（PEM 格式）。
String extractPublicKeyFromCertificate(String certificate) {
  final cert = X509Utils.x509CertificateFromPem(certificate);
  final publicHex = cert.tbsCertificate!.subjectPublicKeyInfo.bytes!;
  return _hexToSpkiPem(publicHex);
}

String _hexToSpkiPem(String hexBytes) {
  final publicBytes = hex.decode(hexBytes);
  final publicBase64 = base64Encode(publicBytes);
  final temp =
      '-----BEGIN PUBLIC KEY-----\n$publicBase64\n-----END PUBLIC KEY-----';
  return X509Utils.fixPem(temp);
}
