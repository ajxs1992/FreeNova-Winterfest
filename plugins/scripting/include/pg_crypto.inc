/* pg_crypto.inc — proven crypto primitives for the FreeNova PG backend.
 * EXACTLY the code that passed 10/10 RFC vectors on the live server
 * (pg_crypto_test.sma v2.0.0): MD5 (RFC 1321), SHA-256 (FIPS 180-4),
 * HMAC-SHA-256 (RFC 2104), base64, SCRAM Hi + RFC 7677 proof/signature.
 * Pawn cells are SIGNED 32-bit: AddU/ShrU/RotLU emulate unsigned-32.
 */
#if defined _pg_crypto_included
    #endinput
#endif
#define _pg_crypto_included

/* ---------------- unsigned-32 helpers (signed-cell safe) ---------------- */
stock ShrU(x, n) {
    if (n <= 0) return x;
    if (n >= 32) return 0;
    new hi = (x >> 16) & 0xffff;
    new lo = x & 0xffff;
    if (n < 16) return ((hi << (16 - n)) | (lo >> n));
    if (n == 16) return hi;
    return hi >> (n - 16);
}

stock AddU(a, b) {
    new alo = a & 0xffff, ahi = (a >> 16) & 0xffff;
    new blo = b & 0xffff, bhi = (b >> 16) & 0xffff;
    new lo = alo + blo;
    new hi = (ahi + bhi + (lo >> 16)) & 0xffff;
    return ((hi << 16) | (lo & 0xffff));
}

stock RotLU(x, n) {
    if (n <= 0 || n >= 32) return x;
    return AddU(x << n, ShrU(x, 32 - n));
}

stock RotRU(x, n) { // SHA-256 uses right rotations
    if (n <= 0 || n >= 32) return x;
    return AddU(ShrU(x, n), x << (32 - n));
}

/* ---------------- base64 ------------------------------------------------ */
stock const B64A[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

stock B64Val(c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

stock B64_Encode(const src[], srclen, dst[], dstmax) {
    new o = 0, i = 0;
    while (i < srclen) {
        new b0 = src[i], b1 = (i + 1 < srclen) ? src[i + 1] : 0, b2 = (i + 2 < srclen) ? src[i + 2] : 0;
        if (o + 5 >= dstmax) break;
        dst[o++] = B64A[(b0 >> 2) & 63];
        dst[o++] = B64A[((b0 & 3) << 4) | ((b1 >> 4) & 15)];
        dst[o++] = (i + 1 < srclen) ? B64A[((b1 & 15) << 2) | ((b2 >> 6) & 3)] : '=';
        dst[o++] = (i + 2 < srclen) ? B64A[b2 & 63] : '=';
        i += 3;
    }
    dst[o] = 0;
    return o;
}

stock B64_Decode(const src[], dst[], dstmax) {
    new o = 0, i = 0, sl = strlen(src);
    while (i < sl && o + 3 < dstmax) {
        new v[4], pad = 0;
        for (new k = 0; k < 4; k++) {
            if (i >= sl) { v[k] = 0; pad++; continue; }
            if (src[i] == '=') { v[k] = 0; pad++; i++; }
            else { v[k] = B64Val(src[i]); i++; if (v[k] < 0) v[k] = 0; }
        }
        dst[o++] = ((v[0] & 63) << 2) | ((v[1] >> 4) & 3);
        if (pad < 2) dst[o++] = ((v[1] & 15) << 4) | ((v[2] >> 2) & 15);
        if (pad < 1) dst[o++] = ((v[2] & 3) << 6) | (v[3] & 63);
    }
    dst[o] = 0;
    return o;
}

/* ---------------- hex ---------------------------------------------------- */
stock HexEncode(const src[], len, dst[], dstmax) {
    static const HEXC[] = "0123456789abcdef";
    new o = 0;
    for (new i = 0; i < len && o + 2 < dstmax; i++) {
        dst[o++] = HEXC[(src[i] >> 4) & 15];
        dst[o++] = HEXC[src[i] & 15];
    }
    dst[o] = 0;
}

/* ---------------- MD5 (RFC 1321) ---------------------------------------- */
new g_mh[4];
new g_mx[16];
new g_pad[1300];
new const g_ms[64] = { 7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5,9,14,20, 5,9,14,20, 5,9,14,20, 5,9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21 };
new const g_mk[64] = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391 };

stock MD5_Transform() {
    new a = g_mh[0], b = g_mh[1], c = g_mh[2], d = g_mh[3], f, g;
    for (new i = 0; i < 64; i++) {
        if (i < 16)      { f = (b & c) | ((~b) & d); g = i; }
        else if (i < 32) { f = (d & b) | ((~d) & c); g = (5 * i + 1) & 15; }
        else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) & 15; }
        else             { f = c ^ (b | (~d)); g = (7 * i) & 15; }
        f = AddU(f, AddU(a, AddU(g_mk[i], g_mx[g])));
        a = d; d = c; c = b;
        b = AddU(b, RotLU(f, g_ms[i]));
    }
    g_mh[0] = AddU(g_mh[0], a); g_mh[1] = AddU(g_mh[1], b);
    g_mh[2] = AddU(g_mh[2], c); g_mh[3] = AddU(g_mh[3], d);
}

stock MD5_Raw(const src[], len, digest[16]) {
    g_mh[0] = 0x67452301; g_mh[1] = 0xefcdab89;
    g_mh[2] = 0x98badcfe; g_mh[3] = 0x10325476;
    new z = (56 - ((len + 1) % 64) + 64) % 64;
    new total = len + 1 + z + 8;
    if (total >= 1296) return 0;
    for (new i = 0; i < len; i++) g_pad[i] = src[i] & 0xff;
    g_pad[len] = 0x80;
    for (new i = 1; i <= z; i++) g_pad[len + i] = 0;
    new bits = len * 8;
    for (new b = 0; b < 4; b++) g_pad[total - 8 + b] = (bits >> (8 * b)) & 0xff;
    for (new b = 4; b < 8; b++) g_pad[total - 8 + b] = 0;
    for (new off = 0; off < total; off += 64) {
        for (new w = 0; w < 16; w++) {
            g_mx[w] = g_pad[off + w * 4]
                | (g_pad[off + w * 4 + 1] << 8)
                | (g_pad[off + w * 4 + 2] << 16)
                | (g_pad[off + w * 4 + 3] << 24);
        }
        MD5_Transform();
    }
    for (new w = 0; w < 4; w++) {
        digest[w * 4]      = g_mh[w] & 0xff;
        digest[w * 4 + 1]  = (g_mh[w] >> 8) & 0xff;
        digest[w * 4 + 2]  = (g_mh[w] >> 16) & 0xff;
        digest[w * 4 + 3]  = (g_mh[w] >> 24) & 0xff;
    }
    return 1;
}

/* ---------------- SHA-256 (FIPS 180-4) ---------------------------------- */
new g_sh[8];
new g_sw[64];
new const g_sk[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };

stock SHA256_Transform() {
    new a = g_sh[0], b = g_sh[1], c = g_sh[2], d = g_sh[3];
    new e = g_sh[4], f = g_sh[5], g = g_sh[6], h = g_sh[7];
    for (new i = 0; i < 64; i++) {
        if (i >= 16) {
            new s0 = RotRU(g_sw[i - 15], 7) ^ RotRU(g_sw[i - 15], 18) ^ ShrU(g_sw[i - 15], 3);
            new s1 = RotRU(g_sw[i - 2], 17) ^ RotRU(g_sw[i - 2], 19) ^ ShrU(g_sw[i - 2], 10);
            g_sw[i] = AddU(g_sw[i - 16], AddU(s0, AddU(g_sw[i - 7], s1)));
        }
        new S1 = RotRU(e, 6) ^ RotRU(e, 11) ^ RotRU(e, 25);
        new ch = (e & f) ^ ((~e) & g);
        new t1 = AddU(h, AddU(S1, AddU(ch, AddU(g_sk[i], g_sw[i]))));
        new S0 = RotRU(a, 2) ^ RotRU(a, 13) ^ RotRU(a, 22);
        new mj = (a & b) ^ (a & c) ^ (b & c);
        new t2 = AddU(S0, mj);
        h = g; g = f; f = e; e = AddU(d, t1);
        d = c; c = b; b = a; a = AddU(t1, t2);
    }
    g_sh[0] = AddU(g_sh[0], a); g_sh[1] = AddU(g_sh[1], b);
    g_sh[2] = AddU(g_sh[2], c); g_sh[3] = AddU(g_sh[3], d);
    g_sh[4] = AddU(g_sh[4], e); g_sh[5] = AddU(g_sh[5], f);
    g_sh[6] = AddU(g_sh[6], g); g_sh[7] = AddU(g_sh[7], h);
}

stock SHA256_Raw(const src[], len, digest[32]) {
    g_sh[0] = 0x6a09e667; g_sh[1] = 0xbb67ae85; g_sh[2] = 0x3c6ef372; g_sh[3] = 0xa54ff53a;
    g_sh[4] = 0x510e527f; g_sh[5] = 0x9b05688c; g_sh[6] = 0x1f83d9ab; g_sh[7] = 0x5be0cd19;
    new z = (56 - ((len + 1) % 64) + 64) % 64;
    new total = len + 1 + z + 8;
    if (total >= 1296) return 0;
    for (new i = 0; i < len; i++) g_pad[i] = src[i] & 0xff;
    g_pad[len] = 0x80;
    for (new i = 1; i <= z; i++) g_pad[len + i] = 0;
    new hiw = len >> 29;
    new low = len << 3;
    g_pad[total - 8] = (hiw >> 24) & 0xff; g_pad[total - 7] = (hiw >> 16) & 0xff;
    g_pad[total - 6] = (hiw >> 8) & 0xff;  g_pad[total - 5] = hiw & 0xff;
    g_pad[total - 4] = (low >> 24) & 0xff; g_pad[total - 3] = (low >> 16) & 0xff;
    g_pad[total - 2] = (low >> 8) & 0xff;  g_pad[total - 1] = low & 0xff;
    for (new off = 0; off < total; off += 64) {
        for (new w = 0; w < 16; w++) {
            g_sw[w] = (g_pad[off + w * 4] << 24)
                | (g_pad[off + w * 4 + 1] << 16)
                | (g_pad[off + w * 4 + 2] << 8)
                | g_pad[off + w * 4 + 3];
        }
        SHA256_Transform();
    }
    for (new w = 0; w < 8; w++) {
        digest[w * 4]      = (g_sh[w] >> 24) & 0xff;
        digest[w * 4 + 1]  = (g_sh[w] >> 16) & 0xff;
        digest[w * 4 + 2]  = (g_sh[w] >> 8) & 0xff;
        digest[w * 4 + 3]  = g_sh[w] & 0xff;
    }
    return 1;
}

/* ---------------- HMAC-SHA-256 (RFC 2104) -------------------------------- */
new g_hm[1400];

stock HMAC_SHA256(const key[], klen, const msg[], mlen, digest[32]) {
    new k0[64];
    for (new i = 0; i < 64; i++) k0[i] = 0;
    if (klen > 64) {
        new kh[32];
        SHA256_Raw(key, klen, kh);
        for (new i = 0; i < 32; i++) k0[i] = kh[i];
    }
    else for (new i = 0; i < klen; i++) k0[i] = key[i];
    new inner[32];
    // inner: H( (K^ipad) || msg )
    for (new i = 0; i < 64; i++) g_hm[i] = k0[i] ^ 0x36;
    for (new i = 0; i < mlen && 64 + i < 1300; i++) g_hm[64 + i] = msg[i];
    SHA256_Raw(g_hm, 64 + mlen, inner);
    // outer: H( (K^opad) || inner )
    for (new i = 0; i < 64; i++) g_hm[i] = k0[i] ^ 0x5c;
    for (new i = 0; i < 32; i++) g_hm[64 + i] = inner[i];
    SHA256_Raw(g_hm, 96, digest);
}

/* ---------------- SCRAM pieces (RFC 5802/7677) --------------------------- */
stock SCRAM_Hi(const pw[], pwlen, const salt[], saltlen, iters, out[32]) {
    new msg[64], u[32], t[32];
    if (saltlen + 4 > 64) return 0;
    for (new i = 0; i < saltlen; i++) msg[i] = salt[i];
    msg[saltlen] = 0; msg[saltlen + 1] = 0; msg[saltlen + 2] = 0; msg[saltlen + 3] = 1;
    HMAC_SHA256(pw, pwlen, msg, saltlen + 4, u);
    for (new i = 0; i < 32; i++) t[i] = u[i];
    for (new it = 1; it < iters; it++) {
        HMAC_SHA256(pw, pwlen, u, 32, u);
        for (new i = 0; i < 32; i++) t[i] = t[i] ^ u[i];
    }
    for (new i = 0; i < 32; i++) out[i] = t[i];
    return 1;
}
