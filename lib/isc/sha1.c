/*
 * Copyright (C) Internet Systems Consortium, Inc. ("ISC")
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * See the COPYRIGHT file distributed with this work for additional
 * information regarding copyright ownership.
 */

/* $Id$ */

/*	$NetBSD: sha1.c,v 1.5 2000/01/22 22:19:14 mycroft Exp $	*/
/*	$OpenBSD: sha1.c,v 1.9 1997/07/23 21:12:32 kstailey Exp $	*/

/*! \file
 * SHA-1 in C
 * \author By Steve Reid <steve@edmweb.com>
 * 100% Public Domain
 * \verbatim
 * Test Vectors (from FIPS PUB 180-1)
 * "abc"
 *   A9993E36 4706816A BA3E2571 7850C26C 9CD0D89D
 * "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
 *   84983E44 1C3BD26E BAAE4AA1 F95129E5 E54670F1
 * A million repetitions of "a"
 *   34AA973C D4C4DAA4 F61EEB2B DBAD2731 6534016F
 * \endverbatim
 */

#include "config.h"

#include <stdbool.h>

#include <isc/assertions.h>
#include <isc/platform.h>
#include <isc/safe.h>
#include <isc/sha1.h>
#include <isc/string.h>
#include <isc/types.h>
#include <isc/util.h>

#if PKCS11CRYPTO
#include <pk11/internal.h>
#include <pk11/pk11.h>
#endif

#ifdef ISC_PLATFORM_OPENSSLHASH
#if OPENSSL_VERSION_NUMBER < 0x10100000L || defined(LIBRESSL_VERSION_NUMBER)
#define EVP_MD_CTX_new() &(context->_ctx)
#define EVP_MD_CTX_free(ptr) EVP_MD_CTX_cleanup(ptr)
#endif

void
isc_sha1_init(isc_sha1_t *context)
{
	INSIST(context != NULL);

	context->ctx = EVP_MD_CTX_new();
	RUNTIME_CHECK(context->ctx != NULL);
	if (EVP_DigestInit(context->ctx, EVP_sha1()) != 1) {
		FATAL_ERROR(__FILE__, __LINE__, "Cannot initialize SHA1.");
	}
}

void
isc_sha1_invalidate(isc_sha1_t *context) {
	EVP_MD_CTX_free(context->ctx);
	context->ctx = NULL;
}

void
isc_sha1_update(isc_sha1_t *context, const unsigned char *data,
		unsigned int len)
{
	INSIST(context != 0);
	INSIST(context->ctx != 0);
	INSIST(data != 0);

	RUNTIME_CHECK(EVP_DigestUpdate(context->ctx,
				       (const void *) data,
				       (size_t) len) == 1);
}

void
isc_sha1_final(isc_sha1_t *context, unsigned char *digest) {
	INSIST(digest != 0);
	INSIST(context != 0);
	INSIST(context->ctx != 0);

	RUNTIME_CHECK(EVP_DigestFinal(context->ctx, digest, NULL) == 1);
	EVP_MD_CTX_free(context->ctx);
	context->ctx = NULL;
}

#elif PKCS11CRYPTO

void
isc_sha1_init(isc_sha1_t *ctx) {
	CK_RV rv;
	CK_MECHANISM mech = { CKM_SHA_1, NULL, 0 };

	RUNTIME_CHECK(pk11_get_session(ctx, OP_DIGEST, true, false,
				       false, NULL, 0) == ISC_R_SUCCESS);
	PK11_FATALCHECK(pkcs_C_DigestInit, (ctx->session, &mech));
}

void
isc_sha1_invalidate(isc_sha1_t *ctx) {
	CK_BYTE garbage[ISC_SHA1_DIGESTLENGTH];
	CK_ULONG len = ISC_SHA1_DIGESTLENGTH;

	if (ctx->handle == NULL)
		return;
	(void) pkcs_C_DigestFinal(ctx->session, garbage, &len);
	isc_safe_memwipe(garbage, sizeof(garbage));
	pk11_return_session(ctx);
}

void
isc_sha1_update(isc_sha1_t *ctx, const unsigned char *buf, unsigned int len) {
	CK_RV rv;
	CK_BYTE_PTR pPart;

	DE_CONST(buf, pPart);
	PK11_FATALCHECK(pkcs_C_DigestUpdate,
			(ctx->session, pPart, (CK_ULONG) len));
}

void
isc_sha1_final(isc_sha1_t *ctx, unsigned char *digest) {
	CK_RV rv;
	CK_ULONG len = ISC_SHA1_DIGESTLENGTH;

	PK11_FATALCHECK(pkcs_C_DigestFinal,
			(ctx->session, (CK_BYTE_PTR) digest, &len));
	pk11_return_session(ctx);
}

#else

#define rol(value, bits) (((value) << (bits)) | ((value) >> (32 - (bits))))

/*@{*/
/*!
 * blk0() and blk() perform the initial expand.
 * I got the idea of expanding during the round function from SSLeay
 */
#if !defined(WORDS_BIGENDIAN)
# define blk0(i) \
	(block->l[i] = (rol(block->l[i], 24) & 0xFF00FF00) \
	 | (rol(block->l[i], 8) & 0x00FF00FF))
#else
# define blk0(i) block->l[i]
#endif
#define blk(i) \
	(block->l[i & 15] = rol(block->l[(i + 13) & 15] \
				^ block->l[(i + 8) & 15] \
				^ block->l[(i + 2) & 15] \
				^ block->l[i & 15], 1))

/*@}*/
/*@{*/
/*!
 * (R0+R1), R2, R3, R4 are the different operations (rounds) used in SHA1
 */
#define R0(v,w,x,y,z,i) \
	z += ((w & (x ^ y)) ^ y) + blk0(i) + 0x5A827999 + rol(v, 5); \
	w = rol(w, 30);
#define R1(v,w,x,y,z,i) \
	z += ((w & (x ^ y)) ^ y) + blk(i) + 0x5A827999 + rol(v, 5); \
	w = rol(w, 30);
#define R2(v,w,x,y,z,i) \
	z += (w ^ x ^ y) + blk(i) + 0x6ED9EBA1 + rol(v, 5); \
	w = rol(w, 30);
#define R3(v,w,x,y,z,i) \
	z += (((w | x) & y) | (w & x)) + blk(i) + 0x8F1BBCDC + rol(v, 5); \
	w = rol(w, 30);
#define R4(v,w,x,y,z,i) \
	z += (w ^ x ^ y) + blk(i) + 0xCA62C1D6 + rol(v, 5); \
	w = rol(w, 30);

/*@}*/

typedef union {
	unsigned char c[64];
	unsigned int l[16];
} CHAR64LONG16;

#ifdef __sparc_v9__
static void do_R01(uint32_t *a, uint32_t *b, uint32_t *c,
		   uint32_t *d, uint32_t *e, CHAR64LONG16 *);
static void do_R2(uint32_t *a, uint32_t *b, uint32_t *c,
		  uint32_t *d, uint32_t *e, CHAR64LONG16 *);
static void do_R3(uint32_t *a, uint32_t *b, uint32_t *c,
		  uint32_t *d, uint32_t *e, CHAR64LONG16 *);
static void do_R4(uint32_t *a, uint32_t *b, uint32_t *c,
		  uint32_t *d, uint32_t *e, CHAR64LONG16 *);

#define nR0(v,w,x,y,z,i) R0(*v,*w,*x,*y,*z,i)
#define nR1(v,w,x,y,z,i) R1(*v,*w,*x,*y,*z,i)
#define nR2(v,w,x,y,z,i) R2(*v,*w,*x,*y,*z,i)
#define nR3(v,w,x,y,z,i) R3(*v,*w,*x,*y,*z,i)
#define nR4(v,w,x,y,z,i) R4(*v,*w,*x,*y,*z,i)

static void
do_R01(uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d,
       uint32_t *e, CHAR64LONG16 *block)
{
	nR0(a,b,c,d,e, 0); nR0(e,a,b,c,d, 1); nR0(d,e,a,b,c, 2);
	nR0(c,d,e,a,b, 3); nR0(b,c,d,e,a, 4); nR0(a,b,c,d,e, 5);
	nR0(e,a,b,c,d, 6); nR0(d,e,a,b,c, 7); nR0(c,d,e,a,b, 8);
	nR0(b,c,d,e,a, 9); nR0(a,b,c,d,e,10); nR0(e,a,b,c,d,11);
	nR0(d,e,a,b,c,12); nR0(c,d,e,a,b,13); nR0(b,c,d,e,a,14);
	nR0(a,b,c,d,e,15); nR1(e,a,b,c,d,16); nR1(d,e,a,b,c,17);
	nR1(c,d,e,a,b,18); nR1(b,c,d,e,a,19);
}

static void
do_R2(uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d,
      uint32_t *e, CHAR64LONG16 *block)
{
	nR2(a,b,c,d,e,20); nR2(e,a,b,c,d,21); nR2(d,e,a,b,c,22);
	nR2(c,d,e,a,b,23); nR2(b,c,d,e,a,24); nR2(a,b,c,d,e,25);
	nR2(e,a,b,c,d,26); nR2(d,e,a,b,c,27); nR2(c,d,e,a,b,28);
	nR2(b,c,d,e,a,29); nR2(a,b,c,d,e,30); nR2(e,a,b,c,d,31);
	nR2(d,e,a,b,c,32); nR2(c,d,e,a,b,33); nR2(b,c,d,e,a,34);
	nR2(a,b,c,d,e,35); nR2(e,a,b,c,d,36); nR2(d,e,a,b,c,37);
	nR2(c,d,e,a,b,38); nR2(b,c,d,e,a,39);
}

static void
do_R3(uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d,
      uint32_t *e, CHAR64LONG16 *block)
{
	nR3(a,b,c,d,e,40); nR3(e,a,b,c,d,41); nR3(d,e,a,b,c,42);
	nR3(c,d,e,a,b,43); nR3(b,c,d,e,a,44); nR3(a,b,c,d,e,45);
	nR3(e,a,b,c,d,46); nR3(d,e,a,b,c,47); nR3(c,d,e,a,b,48);
	nR3(b,c,d,e,a,49); nR3(a,b,c,d,e,50); nR3(e,a,b,c,d,51);
	nR3(d,e,a,b,c,52); nR3(c,d,e,a,b,53); nR3(b,c,d,e,a,54);
	nR3(a,b,c,d,e,55); nR3(e,a,b,c,d,56); nR3(d,e,a,b,c,57);
	nR3(c,d,e,a,b,58); nR3(b,c,d,e,a,59);
}

static void
do_R4(uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d,
      uint32_t *e, CHAR64LONG16 *block)
{
	nR4(a,b,c,d,e,60); nR4(e,a,b,c,d,61); nR4(d,e,a,b,c,62);
	nR4(c,d,e,a,b,63); nR4(b,c,d,e,a,64); nR4(a,b,c,d,e,65);
	nR4(e,a,b,c,d,66); nR4(d,e,a,b,c,67); nR4(c,d,e,a,b,68);
	nR4(b,c,d,e,a,69); nR4(a,b,c,d,e,70); nR4(e,a,b,c,d,71);
	nR4(d,e,a,b,c,72); nR4(c,d,e,a,b,73); nR4(b,c,d,e,a,74);
	nR4(a,b,c,d,e,75); nR4(e,a,b,c,d,76); nR4(d,e,a,b,c,77);
	nR4(c,d,e,a,b,78); nR4(b,c,d,e,a,79);
}
#endif

/*!
 * Hash a single 512-bit block. This is the core of the algorithm.
 */
static void
transform(uint32_t state[5], const unsigned char buffer[64]) {
	uint32_t a, b, c, d, e;
	CHAR64LONG16 *block;
	CHAR64LONG16 workspace;

	INSIST(buffer != NULL);
	INSIST(state != NULL);

	block = &workspace;
	/* cppcheck-suppress uninitvar */
	(void)memmove(block, buffer, 64);

	/* Copy context->state[] to working vars */
	a = state[0];
	b = state[1];
	c = state[2];
	d = state[3];
	e = state[4];

#ifdef __sparc_v9__
	do_R01(&a, &b, &c, &d, &e, block);
	do_R2(&a, &b, &c, &d, &e, block);
	do_R3(&a, &b, &c, &d, &e, block);
	do_R4(&a, &b, &c, &d, &e, block);
#else
	/* 4 rounds of 20 operations each. Loop unrolled. */
	R0(a,b,c,d,e, 0); R0(e,a,b,c,d, 1); R0(d,e,a,b,c, 2); R0(c,d,e,a,b, 3);
	R0(b,c,d,e,a, 4); R0(a,b,c,d,e, 5); R0(e,a,b,c,d, 6); R0(d,e,a,b,c, 7);
	R0(c,d,e,a,b, 8); R0(b,c,d,e,a, 9); R0(a,b,c,d,e,10); R0(e,a,b,c,d,11);
	R0(d,e,a,b,c,12); R0(c,d,e,a,b,13); R0(b,c,d,e,a,14); R0(a,b,c,d,e,15);
	R1(e,a,b,c,d,16); R1(d,e,a,b,c,17); R1(c,d,e,a,b,18); R1(b,c,d,e,a,19);
	R2(a,b,c,d,e,20); R2(e,a,b,c,d,21); R2(d,e,a,b,c,22); R2(c,d,e,a,b,23);
	R2(b,c,d,e,a,24); R2(a,b,c,d,e,25); R2(e,a,b,c,d,26); R2(d,e,a,b,c,27);
	R2(c,d,e,a,b,28); R2(b,c,d,e,a,29); R2(a,b,c,d,e,30); R2(e,a,b,c,d,31);
	R2(d,e,a,b,c,32); R2(c,d,e,a,b,33); R2(b,c,d,e,a,34); R2(a,b,c,d,e,35);
	R2(e,a,b,c,d,36); R2(d,e,a,b,c,37); R2(c,d,e,a,b,38); R2(b,c,d,e,a,39);
	R3(a,b,c,d,e,40); R3(e,a,b,c,d,41); R3(d,e,a,b,c,42); R3(c,d,e,a,b,43);
	R3(b,c,d,e,a,44); R3(a,b,c,d,e,45); R3(e,a,b,c,d,46); R3(d,e,a,b,c,47);
	R3(c,d,e,a,b,48); R3(b,c,d,e,a,49); R3(a,b,c,d,e,50); R3(e,a,b,c,d,51);
	R3(d,e,a,b,c,52); R3(c,d,e,a,b,53); R3(b,c,d,e,a,54); R3(a,b,c,d,e,55);
	R3(e,a,b,c,d,56); R3(d,e,a,b,c,57); R3(c,d,e,a,b,58); R3(b,c,d,e,a,59);
	R4(a,b,c,d,e,60); R4(e,a,b,c,d,61); R4(d,e,a,b,c,62); R4(c,d,e,a,b,63);
	R4(b,c,d,e,a,64); R4(a,b,c,d,e,65); R4(e,a,b,c,d,66); R4(d,e,a,b,c,67);
	R4(c,d,e,a,b,68); R4(b,c,d,e,a,69); R4(a,b,c,d,e,70); R4(e,a,b,c,d,71);
	R4(d,e,a,b,c,72); R4(c,d,e,a,b,73); R4(b,c,d,e,a,74); R4(a,b,c,d,e,75);
	R4(e,a,b,c,d,76); R4(d,e,a,b,c,77); R4(c,d,e,a,b,78); R4(b,c,d,e,a,79);
#endif

	/* Add the working vars back into context.state[] */
	state[0] += a;
	state[1] += b;
	state[2] += c;
	state[3] += d;
	state[4] += e;

	/* Wipe variables */
	a = b = c = d = e = 0;
	/* Avoid compiler warnings */
	POST(a); POST(b); POST(c); POST(d); POST(e);
}


/*!
 * isc_sha1_init - Initialize new context
 */
void
isc_sha1_init(isc_sha1_t *context)
{
	INSIST(context != NULL);

	/* SHA1 initialization constants */
	context->state[0] = 0x67452301;
	context->state[1] = 0xEFCDAB89;
	context->state[2] = 0x98BADCFE;
	context->state[3] = 0x10325476;
	context->state[4] = 0xC3D2E1F0;
	context->count[0] = 0;
	context->count[1] = 0;
}

void
isc_sha1_invalidate(isc_sha1_t *context) {
	isc_safe_memwipe(context, sizeof(*context));
}

/*!
 * Run your data through this.
 */
void
isc_sha1_update(isc_sha1_t *context, const unsigned char *data,
		unsigned int len)
{
	unsigned int i, j;

	INSIST(context != 0);
	INSIST(data != 0);

	j = context->count[0];
	if ((context->count[0] += len << 3) < j)
		context->count[1] += (len >> 29) + 1;
	j = (j >> 3) & 63;
	if ((j + len) > 63) {
		(void)memmove(&context->buffer[j], data, (i = 64 - j));
		transform(context->state, context->buffer);
		for (; i + 63 < len; i += 64)
			transform(context->state, &data[i]);
		j = 0;
	} else {
		i = 0;
	}

	(void)memmove(&context->buffer[j], &data[i], len - i);
}


/*!
 * Add padding and return the message digest.
 */

static const unsigned char final_200 = 128;
static const unsigned char final_0 = 0;

void
isc_sha1_final(isc_sha1_t *context, unsigned char *digest) {
	unsigned int i;
	unsigned char finalcount[8];

	INSIST(digest != 0);
	INSIST(context != 0);

	for (i = 0; i < 8; i++) {
		/* Endian independent */
		finalcount[i] = (unsigned char)
			((context->count[(i >= 4 ? 0 : 1)]
			  >> ((3 - (i & 3)) * 8)) & 255);
	}

	isc_sha1_update(context, &final_200, 1);
	while ((context->count[0] & 504) != 448)
		isc_sha1_update(context, &final_0, 1);
	/* The next Update should cause a transform() */
	isc_sha1_update(context, finalcount, 8);

	if (digest) {
		for (i = 0; i < 20; i++)
			digest[i] = (unsigned char)
				((context->state[i >> 2]
				  >> ((3 - (i & 3)) * 8)) & 255);
	}

	isc_safe_memwipe(context, sizeof(*context));
}
#endif

/*
 * Check for SHA-1 support; if it does not work, raise a fatal error.
 *
 * Use "a" as the test vector.
 *
 * Standard use is testing false and result true.
 * Testing use is testing true and result false;
 */
bool
isc_sha1_check(bool testing) {
	isc_sha1_t ctx;
	unsigned char input = 'a';
	unsigned char digest[ISC_SHA1_DIGESTLENGTH];
	unsigned char expected[] = {
		0x86, 0xf7, 0xe4, 0x37, 0xfa, 0xa5, 0xa7, 0xfc,
		0xe1, 0x5d, 0x1d, 0xdc, 0xb9, 0xea, 0xea, 0xea,
		0x37, 0x76, 0x67, 0xb8
	};

	INSIST(sizeof(expected) == ISC_SHA1_DIGESTLENGTH);

	/*
	 * Introduce a fault for testing.
	 */
	if (testing) {
		input ^= 0x01;
	}

	/*
	 * These functions do not return anything; any failure will be fatal.
	 */
	isc_sha1_init(&ctx);
	isc_sha1_update(&ctx, &input, 1U);
	isc_sha1_final(&ctx, digest);

	/*
	 * Must return true in standard case, should return false for testing.
	 */
	return (memcmp(digest, expected, ISC_SHA1_DIGESTLENGTH) == 0);
}
