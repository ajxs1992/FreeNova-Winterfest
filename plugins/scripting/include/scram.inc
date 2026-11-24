#if defined _scram_included
	#endinput
#endif
#define _scram_included

#include <amxmodx>
#include <sockets>

// SCRAM-SHA-256 client (RFC 7677) for the Postgres engine.
// SHA-256/HMAC are implemented in Pawn so no per-iteration file I/O is needed:
// PBKDF2 at 4096 iterations must run in well under a second.
// The derivation itself is chunked from the engine think (ScramThink).

#define SCRAM_NONE         0
#define SCRAM_SENT_INITIAL 1
#define SCRAM_COMPUTING    2
#define SCRAM_SENT_FINAL   3

#define SCRAM_MAX_CHUNK 8192

new g_scram_phase;
new g_scram_err[128];
new g_scram_cnonce[24];
new g_scram_snonce[96];
new g_scram_c1b[96];
new g_scram_s1[256];
new g_scram_salt[64];
new g_scram_saltlen;
new g_scram_iter;
new g_scram_T[32];
new g_scram_prev[72];
new g_scram_prevlen;
new g_scram_left;
new g_scram_chunk;
new g_scram_servsig[32];
new g_scram_user[64];
new g_scram_pass[64];
new g_scram_ist[8];
new g_scram_ost[8];

new const g_sha_iv[8] = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};

new const g_sha_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

stock ScramReset()
{
	g_scram_phase = SCRAM_NONE;
	g_scram_err[0] = 0;
}

stock Sha256_Rotr(x, n)
{
	return (x >>> n) | (x << (32 - n));
}

stock Sha256_LoadBlock(const data[], pos, w[64])
{
	for( new i = 0; i < 16; i++ )
	{
		new p = pos + i * 4;
		w[i] = (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
	}
	for( new i = 16; i < 64; i++ )
	{
		new s0 = Sha256_Rotr(w[i - 15], 7) ^ Sha256_Rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
		new s1 = Sha256_Rotr(w[i - 2], 17) ^ Sha256_Rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
}

stock Sha256_Compress(hst[8], const w[64])
{
	new a = hst[0], b = hst[1], c = hst[2], d = hst[3];
	new e = hst[4], f = hst[5], g = hst[6], h = hst[7];
	for( new i = 0; i < 64; i++ )
	{
		new S1 = Sha256_Rotr(e, 6) ^ Sha256_Rotr(e, 11) ^ Sha256_Rotr(e, 25);
		new ch = (e & f) ^ (~e & g);
		new t1 = h + S1 + ch + g_sha_k[i] + w[i];
		new S0 = Sha256_Rotr(a, 2) ^ Sha256_Rotr(a, 13) ^ Sha256_Rotr(a, 22);
		new maj = (a & b) ^ (a & c) ^ (b & c);
		new t2 = S0 + maj;
		h = g; g = f; f = e; e = d + t1;
		d = c; c = b; b = a; a = t1 + t2;
	}
	hst[0] += a; hst[1] += b; hst[2] += c; hst[3] += d;
	hst[4] += e; hst[5] += f; hst[6] += g; hst[7] += h;
}

// Hash len bytes of data starting from an already-absorbed state.
// absorbed = bytes already compressed into state (0 for a fresh hash).
stock Sha256_FromState(const hst[8], const data[], len, absorbed, out[32])
{
	new st[8];
	for( new i = 0; i < 8; i++ )
		st[i] = hst[i];

	new w[64];
	new pos = 0;
	while( len - pos >= 64 )
	{
		Sha256_LoadBlock(data, pos, w);
		Sha256_Compress(st, w);
		pos += 64;
	}

	new tail[128];
	new rem = len - pos;
	for( new i = 0; i < rem; i++ )
		tail[i] = data[pos + i];
	tail[rem] = 0x80;
	new blocks = (rem < 56) ? 1 : 2;
	new total = blocks * 64;
	for( new i = rem + 1; i < total - 8; i++ )
		tail[i] = 0;
	new bits = (absorbed + len) * 8;
	tail[total - 8] = 0;
	tail[total - 7] = 0;
	tail[total - 6] = 0;
	tail[total - 5] = 0;
	tail[total - 4] = (bits >>> 24) & 255;
	tail[total - 3] = (bits >>> 16) & 255;
	tail[total - 2] = (bits >>> 8) & 255;
	tail[total - 1] = bits & 255;

	for( new b = 0; b < blocks; b++ )
	{
		Sha256_LoadBlock(tail, b * 64, w);
		Sha256_Compress(st, w);
	}

	for( new i = 0; i < 8; i++ )
	{
		new v = st[i];
		out[i * 4] = (v >>> 24) & 255;
		out[i * 4 + 1] = (v >>> 16) & 255;
		out[i * 4 + 2] = (v >>> 8) & 255;
		out[i * 4 + 3] = v & 255;
	}
}

stock Sha256(const data[], len, out[32])
{
	Sha256_FromState(g_sha_iv, data, len, 0, out);
}

// Precompute HMAC ipad/opad states so each PBKDF2 round costs 2 compressions.
stock Hmac_Setup(const key[], klen, inner[8], outer[8])
{
	new kbin[64];
	for( new i = 0; i < 64; i++ )
		kbin[i] = 0;

	new kl = klen;
	if( kl > 64 )
	{
		new kd[32];
		Sha256(key, klen, kd);
		for( new i = 0; i < 32; i++ )
			kbin[i] = kd[i];
		kl = 32;
	}
	else
	{
		for( new i = 0; i < kl; i++ )
			kbin[i] = key[i] & 255;
	}

	new blk[64], w[64];
	for( new i = 0; i < 64; i++ )
		blk[i] = kbin[i] ^ 0x36;
	for( new i = 0; i < 8; i++ )
		inner[i] = g_sha_iv[i];
	Sha256_LoadBlock(blk, 0, w);
	Sha256_Compress(inner, w);

	for( new i = 0; i < 64; i++ )
		blk[i] = kbin[i] ^ 0x5c;
	for( new i = 0; i < 8; i++ )
		outer[i] = g_sha_iv[i];
	Sha256_LoadBlock(blk, 0, w);
	Sha256_Compress(outer, w);
}

stock Hmac_States(const inner[8], const outer[8], const msg[], mlen, out[32])
{
	new ist[8], ost[8], digest[32];
	for( new i = 0; i < 8; i++ )
		ist[i] = inner[i];
	Sha256_FromState(ist, msg, mlen, 64, digest);
	for( new i = 0; i < 8; i++ )
		ost[i] = outer[i];
	Sha256_FromState(ost, digest, 32, 64, out);
}

stock Hmac(const key[], klen, const msg[], mlen, out[32])
{
	new ist[8], ost[8];
	Hmac_Setup(key, klen, ist, ost);
	Hmac_States(ist, ost, msg, mlen, out);
}

stock Scram_B64Val(c)
{
	if( c >= 'A' && c <= 'Z' ) return c - 'A';
	if( c >= 'a' && c <= 'z' ) return c - 'a' + 26;
	if( c >= '0' && c <= '9' ) return c - '0' + 52;
	if( c == '+' ) return 62;
	if( c == '/' ) return 63;
	return -1;
}

stock Scram_B64Encode(const data[], len, out[], outmax)
{
	new alpha[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	new o = 0, i = 0;
	while( i < len )
	{
		new b0 = data[i++] & 255;
		new b1 = (i < len) ? (data[i++] & 255) : 0;
		new b2 = (i < len) ? (data[i++] & 255) : 0;
		if( o + 4 >= outmax ) return -1;
		out[o++] = alpha[(b0 >> 2) & 63];
		out[o++] = alpha[((b0 << 4) | (b1 >> 4)) & 63];
		out[o++] = alpha[((b1 << 2) | (b2 >> 6)) & 63];
		out[o++] = alpha[b2 & 63];
	}
	new rem = len % 3;
	if( rem == 1 )
	{
		out[o - 2] = '=';
		out[o - 1] = '=';
	}
	else if( rem == 2 )
		out[o - 1] = '=';
	out[o] = 0;
	return o;
}

stock Scram_B64Decode(const s[], out[], outmax)
{
	new sl = strlen(s);
	if( sl % 4 != 0 ) return -1;
	new o = 0;
	for( new i = 0; i < sl; i += 4 )
	{
		new v[4];
		new pad = 0;
		for( new k = 0; k < 4; k++ )
		{
			if( s[i + k] == '=' ) { v[k] = 0; pad++; }
			else
			{
				v[k] = Scram_B64Val(s[i + k]);
				if( v[k] < 0 ) return -1;
			}
		}
		new room = 3 - pad;
		if( o + room > outmax ) return -1;
		out[o++] = (v[0] << 2) | (v[1] >> 4);
		if( pad < 2 ) out[o++] = ((v[1] << 4) | (v[2] >> 2)) & 255;
		if( pad < 1 ) out[o++] = ((v[2] << 6) | v[3]) & 255;
	}
	return o;
}

// Find attribute "key=" (at start or after ','); copy value to out.
stock bool:Scram_Attr(const msg[], const key[], out[], outmax)
{
	new kl = strlen(key);
	new ml = strlen(msg);
	for( new i = 0; i < ml; i++ )
	{
		if( i > 0 && msg[i - 1] != ',' ) continue;
		new k = 0;
		while( k < kl && msg[i + k] == key[k] )
			k++;
		if( k == kl && msg[i + k] == '=' )
		{
			new o = 0, p = i + k + 1;
			while( p < ml && msg[p] != ',' && o < outmax - 1 )
				out[o++] = msg[p++];
			out[o] = 0;
			return true;
		}
	}
	return false;
}

stock bool:Scram_SendRaw(sock, const buf[], len)
{
	if( sock < 0 || len <= 0 ) return false;
	return socket_send2(sock, buf, len) > 0;
}

// AuthenticationSASL (method 10) -> send SASLInitialResponse.
stock bool:ScramBegin(sock, const user[], const pass[], const mechs[], mechlen)
{
	new ml = mechlen;
	if( ml > 127 ) ml = 127;
	new mbuf[128];
	for( new i = 0; i < ml; i++ )
		mbuf[i] = mechs[i];
	mbuf[ml] = 0;
	if( contain(mbuf, "SCRAM-SHA-256") == -1 )
	{
		copy(g_scram_err, charsmax(g_scram_err), "SCRAM-SHA-256 not offered");
		return false;
	}
	copy(g_scram_user, charsmax(g_scram_user), user);
	copy(g_scram_pass, charsmax(g_scram_pass), pass);
	for( new i = 0; i < 18; i++ )
	{
		new r = random_num(0, 61);
		g_scram_cnonce[i] = (r < 10) ? ('0' + r) : ((r < 36) ? ('A' + r - 10) : ('a' + r - 36));
	}
	g_scram_cnonce[18] = 0;
	formatex(g_scram_c1b, charsmax(g_scram_c1b), "n=%s,r=%s", user, g_scram_cnonce);

	new c1len = strlen(g_scram_c1b);
	new initlen = 3 + c1len;
	new total = 4 + 14 + 4 + initlen;
	new pkt[192];
	new n = 0;
	pkt[n++] = 'p';
	pkt[n++] = (total >> 24) & 255;
	pkt[n++] = (total >> 16) & 255;
	pkt[n++] = (total >> 8) & 255;
	pkt[n++] = total & 255;
	pkt[n++] = 'S'; pkt[n++] = 'C'; pkt[n++] = 'R'; pkt[n++] = 'A'; pkt[n++] = 'M';
	pkt[n++] = '-'; pkt[n++] = 'S'; pkt[n++] = 'H'; pkt[n++] = 'A'; pkt[n++] = '-';
	pkt[n++] = '2'; pkt[n++] = '5'; pkt[n++] = '6'; pkt[n++] = 0;
	pkt[n++] = (initlen >> 24) & 255;
	pkt[n++] = (initlen >> 16) & 255;
	pkt[n++] = (initlen >> 8) & 255;
	pkt[n++] = initlen & 255;
	pkt[n++] = 'n'; pkt[n++] = ','; pkt[n++] = ',';
	for( new i = 0; i < c1len; i++ )
		pkt[n++] = g_scram_c1b[i];

	if( !Scram_SendRaw(sock, pkt, n) )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram initial send failed");
		return false;
	}
	g_scram_phase = SCRAM_SENT_INITIAL;
	return true;
}

// AuthenticationSASLContinue (method 11) payload -> precompute key states.
stock bool:ScramOnServerFirst(const data[], datalen)
{
	new s1[256];
	new dl = datalen;
	if( dl > 255 ) dl = 255;
	for( new i = 0; i < dl; i++ )
		s1[i] = data[i];
	s1[dl] = 0;
	if( s1[0] == 'e' && s1[1] == '=' )
	{
		formatex(g_scram_err, charsmax(g_scram_err), "scram error: %s", s1);
		return false;
	}
	copy(g_scram_s1, charsmax(g_scram_s1), s1);
	if( !Scram_Attr(s1, "r", g_scram_snonce, charsmax(g_scram_snonce))
	 || !equal(g_scram_snonce, g_scram_cnonce, strlen(g_scram_cnonce)) )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram nonce mismatch");
		return false;
	}
	new saltb64[96];
	if( !Scram_Attr(s1, "s", saltb64, charsmax(saltb64)) )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram salt missing");
		return false;
	}
	g_scram_saltlen = Scram_B64Decode(saltb64, g_scram_salt, sizeof(g_scram_salt));
	if( g_scram_saltlen <= 0 || g_scram_saltlen > 64 )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram salt decode failed");
		return false;
	}
	new iters[16];
	if( !Scram_Attr(s1, "i", iters, charsmax(iters)) )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram iteration missing");
		return false;
	}
	g_scram_iter = str_to_num(iters);
	if( g_scram_iter < 1 || g_scram_iter > 1000000 )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram iteration out of range");
		return false;
	}

	for( new i = 0; i < 32; i++ )
		g_scram_T[i] = 0;
	for( new i = 0; i < g_scram_saltlen; i++ )
		g_scram_prev[i] = g_scram_salt[i];
	g_scram_prev[g_scram_saltlen] = 0;
	g_scram_prev[g_scram_saltlen + 1] = 0;
	g_scram_prev[g_scram_saltlen + 2] = 0;
	g_scram_prev[g_scram_saltlen + 3] = 1;
	g_scram_prevlen = g_scram_saltlen + 4;

	Hmac_Setup(g_scram_pass, strlen(g_scram_pass), g_scram_ist, g_scram_ost);
	g_scram_left = g_scram_iter;
	// Spread the derivation over ~8 thinks so a server tick never stalls long.
	g_scram_chunk = g_scram_iter / 8;
	if( g_scram_chunk < 32 ) g_scram_chunk = 32;
	if( g_scram_chunk > SCRAM_MAX_CHUNK ) g_scram_chunk = SCRAM_MAX_CHUNK;
	g_scram_phase = SCRAM_COMPUTING;
	return true;
}

// One think of PBKDF2; sends client-final when done.
// Returns 1 = sent final, 0 = still computing, -1 = error (g_scram_err).
stock ScramThink(sock)
{
	if( g_scram_phase != SCRAM_COMPUTING ) return 0;
	new U[32];
	new k = g_scram_chunk;
	if( k <= 0 ) k = 32;
	while( k > 0 && g_scram_left > 0 )
	{
		Hmac_States(g_scram_ist, g_scram_ost, g_scram_prev, g_scram_prevlen, U);
		for( new i = 0; i < 32; i++ )
		{
			g_scram_T[i] = g_scram_T[i] ^ U[i];
			g_scram_prev[i] = U[i];
		}
		g_scram_prevlen = 32;
		g_scram_left--;
		k--;
	}
	if( g_scram_left > 0 ) return 0;
	return ScramFinish(sock);
}

stock ScramFinish(sock)
{
	new clientkey[32], storedkey[32];
	Hmac(g_scram_T, 32, "Client Key", 10, clientkey);
	Sha256(clientkey, 32, storedkey);

	new c2wop[160];
	formatex(c2wop, charsmax(c2wop), "c=biws,r=%s", g_scram_snonce);
	new authmsg[512];
	formatex(authmsg, charsmax(authmsg), "%s,%s,%s", g_scram_c1b, g_scram_s1, c2wop);
	new authlen = strlen(authmsg);

	new clientsig[32];
	Hmac(storedkey, 32, authmsg, authlen, clientsig);
	new proof[32];
	for( new i = 0; i < 32; i++ )
		proof[i] = clientkey[i] ^ clientsig[i];
	new proofb64[48];
	if( Scram_B64Encode(proof, 32, proofb64, charsmax(proofb64)) < 0 )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram proof encode failed");
		return -1;
	}

	new serverkey[32];
	Hmac(g_scram_T, 32, "Server Key", 10, serverkey);
	Hmac(serverkey, 32, authmsg, authlen, g_scram_servsig);

	new c2[224];
	formatex(c2, charsmax(c2), "%s,p=%s", c2wop, proofb64);
	new c2len = strlen(c2);
	new pkt[256];
	new n = 0;
	pkt[n++] = 'p';
	new total = 4 + c2len;
	pkt[n++] = (total >> 24) & 255;
	pkt[n++] = (total >> 16) & 255;
	pkt[n++] = (total >> 8) & 255;
	pkt[n++] = total & 255;
	for( new i = 0; i < c2len; i++ )
		pkt[n++] = c2[i];

	if( !Scram_SendRaw(sock, pkt, n) )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram final send failed");
		return -1;
	}
	g_scram_phase = SCRAM_SENT_FINAL;
	return 1;
}

// AuthenticationSASLFinal (method 12) payload -> verify server signature.
stock bool:ScramOnServerFinal(const data[], datalen)
{
	new s[128];
	new dl = datalen;
	if( dl > 127 ) dl = 127;
	for( new i = 0; i < dl; i++ )
		s[i] = data[i];
	s[dl] = 0;
	if( s[0] == 'e' && s[1] == '=' )
	{
		formatex(g_scram_err, charsmax(g_scram_err), "scram error: %s", s);
		return false;
	}
	new sigb64[64];
	if( !Scram_Attr(s, "v", sigb64, charsmax(sigb64)) )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram server signature missing");
		return false;
	}
	new sig[32];
	if( Scram_B64Decode(sigb64, sig, sizeof(sig)) != 32 )
	{
		copy(g_scram_err, charsmax(g_scram_err), "scram server signature decode failed");
		return false;
	}
	for( new i = 0; i < 32; i++ )
	{
		if( sig[i] != g_scram_servsig[i] )
		{
			copy(g_scram_err, charsmax(g_scram_err), "scram server signature mismatch");
			return false;
		}
	}
	return true;
}
