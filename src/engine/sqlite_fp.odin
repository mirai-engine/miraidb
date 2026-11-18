package engine

import "base:intrinsics"
import "core:mem"

// ---------------------------------------------------------------------------
// Doubles: sqlite3FpDecode (util.c), ported as SQLite has it. SQLite does not
// convert a double to decimal exactly: it takes 18 digits with its own
// approximate scaling (sqlite3Fp2Convert10) and rounds those half away from
// zero, so its last digit can differ from a correctly rounded conversion. The
// text has to be SQLite's, so the conversion is SQLite's too.

Fp_Decode :: struct {
	sign:    u8, // '+' or '-'
	special: int, // 0, 1 for an infinity, 2 for NaN
	buffer:  [24]u8,
	start:   int, // the first digit is buffer[start]
	n:       int,
	dp:      int, // the decimal point follows digit dp (iDP)
}

fp_digit :: #force_inline proc(d: ^Fp_Decode, k: int) -> u8 {
	return d.buffer[d.start + k]
}

@(private)
POW10_BASE := [27]u64 {
	0x8000000000000000, 0xa000000000000000, 0xc800000000000000, 0xfa00000000000000,
	0x9c40000000000000, 0xc350000000000000, 0xf424000000000000, 0x9896800000000000,
	0xbebc200000000000, 0xee6b280000000000, 0x9502f90000000000, 0xba43b74000000000,
	0xe8d4a51000000000, 0x9184e72a00000000, 0xb5e620f480000000, 0xe35fa931a0000000,
	0x8e1bc9bf04000000, 0xb1a2bc2ec5000000, 0xde0b6b3a76400000, 0x8ac7230489e80000,
	0xad78ebc5ac620000, 0xd8d726b7177a8000, 0x878678326eac9000, 0xa968163f0a57b400,
	0xd3c21bcecceda100, 0x84595161401484a0, 0xa56fa5b99019a5c8,
}

@(private)
POW10_SCALE := [26]u64 {
	0x8049a4ac0c5811ae, 0xcf42894a5dce35ea, 0xa76c582338ed2621, 0x873e4f75e2224e68,
	0xda7f5bf590966848, 0xb080392cc4349dec, 0x8e938662882af53e, 0xe65829b3046b0afa,
	0xba121a4650e4ddeb, 0x964e858c91ba2655, 0xf2d56790ab41c2a2, 0xc428d05aa4751e4c,
	0x9e74d1b791e07e48, 0xcccccccccccccccc, 0xcecb8f27f4200f3a, 0xa70c3c40a64e6c51,
	0x86f0ac99b4e8dafd, 0xda01ee641a708de9, 0xb01ae745b101e9e4, 0x8e41ade9fbebc27d,
	0xe5d3ef282a242e81, 0xb9a74a0637ce2ee1, 0x95f83d0a1fb69cd9, 0xf24a01a73cf2dccf,
	0xc3b8358109e84f07, 0x9e19db92b4e31ba9,
}

@(private)
POW10_SCALE_LO := [26]u32 {
	0x205b896d, 0x52064cad, 0xaf2af2b8, 0x5a7744a7, 0xaf39a475, 0xbd8d794e, 0x547eb47b,
	0x0cb4a5a3, 0x92f34d62, 0x3a6a07f9, 0xfae27299, 0xaa97e14c, 0x775ea265, 0xcccccccc,
	0x00000000, 0x999090b6, 0x69a028bb, 0xe80e6f48, 0x5ec05dd0, 0x14588f14, 0x8f1668c9,
	0x6d953e2c, 0x4abdaf10, 0xbc633b39, 0x0a862f81, 0x6c07a2c2,
}

@(private)
POWERS_OF_10_FIRST :: -348
@(private)
POWERS_OF_10_LAST :: 347

@(private)
fp_multiply128 :: proc(a, b: u64) -> (hi: u64, lo: u64) {
	r := u128(a) * u128(b)
	return u64(r >> 64), u64(r)
}

@(private)
fp_multiply160 :: proc(a: u64, a_lo: u32, b: u64) -> (hi: u64, lo: u32) {
	r := u128(a) * u128(b)
	r += (u128(a_lo) * u128(b)) >> 32
	return u64(r >> 64), u32((r >> 32) & 0xffffffff)
}

@(private)
fp_power_of_ten :: proc(p: int) -> (hi: u64, lo: u32) {
	g, n: int
	if p < 0 {
		if p == -1 do return POW10_SCALE[13], POW10_SCALE_LO[13]
		g = p / 27
		n = p % 27
		if n != 0 {
			g -= 1
			n += 27
		}
	} else if p < 27 {
		return POW10_BASE[p], 0
	} else {
		g = p / 27
		n = p % 27
	}
	s := POW10_SCALE[g + 13]
	if n == 0 do return s, POW10_SCALE_LO[g + 13]
	x, l := fp_multiply160(s, POW10_SCALE_LO[g + 13], POW10_BASE[n])
	if x & (u64(1) << 63) == 0 {
		x = x << 1 | u64((l >> 31) & 1)
		l = (l << 1) | 1
	}
	return x, l
}

@(private)
fp_pwr10to2 :: #force_inline proc(p: int) -> int {return (p * 108853) >> 15}
@(private)
fp_pwr2to10 :: #force_inline proc(p: int) -> int {return (p * 78913) >> 18}

@(private)
fp_count_leading_zeros :: proc(m: u64) -> int {
	return int(intrinsics.count_leading_zeros(m))
}

// fp2_convert10: r == m*2^e becomes d*10^p with at least n digits.
@(private)
fp2_convert10 :: proc(m: u64, e: int, n: int) -> (d: u64, p: int) {
	q := n - 1 - fp_pwr2to10(e + 63)
	pow_hi, _ := fp_power_of_ten(q)
	h, _ := fp_multiply128(m, pow_hi)
	if n == 18 {
		h >>= uint(-(e + fp_pwr10to2(q) + 2))
		d = (h + ((h << 1) & 2)) >> 1
	} else {
		d = h >> uint(-(e + fp_pwr10to2(q) + 1))
	}
	return d, -q
}

// fp10_convert2 is the double nearest d*10^p (Ross Cox's method, as SQLite).
@(private)
fp10_convert2 :: proc(d: u64, p: int) -> f64 {
	if p < POWERS_OF_10_FIRST do return 0
	if p > POWERS_OF_10_LAST do return transmute(f64)u64(0x7ff0000000000000)
	b := 64 - fp_count_leading_zeros(d)
	lp := fp_pwr10to2(p)
	e := 53 - b - lp
	if e > 1074 {
		if e >= 1130 do return 0
		e = 1074
	}
	s := -(e - (64 - b) + lp + 3)
	pwr10h, pwr10l := fp_power_of_ten(p)
	if pwr10l != 0 {
		pwr10h += 1
		pwr10l = ~pwr10l
	}
	x := d << uint(64 - b)
	hi, lo := fp_multiply128(x, pwr10h)
	mid1 := u32(lo >> 32)
	sticky: u64 = 1
	if hi & ((u64(1) << uint(s)) - 1) == 0 {
		mid2_hi, _ := fp_multiply128(x, u64(pwr10l) << 32)
		mid2 := u32(mid2_hi)
		sticky = mid1 - mid2 > 1 ? 1 : 0
		if mid1 < mid2 do hi -= 1
	}
	u := (hi >> uint(s)) | sticky
	adj := u >= (u64(1) << 55) - 2 ? 1 : 0
	if adj != 0 {
		u = (u >> uint(adj)) | (u & 1)
		e -= adj
	}
	m := (u + 1 + ((u >> 2) & 1)) >> 2
	if e <= -972 do return transmute(f64)u64(0x7ff0000000000000)
	if m & (u64(1) << 52) != 0 {
		m = (m & ~(u64(1) << 52)) | (u64(1075 - e) << 52)
	}
	return transmute(f64)m
}

// fp_decode is sqlite3FpDecode: iRound <= 0 rounds to -iRound digits right of
// the point, a positive iRound to that many significant digits, and never more
// than mxRound significant digits.
fp_decode :: proc(value: f64, iRound_in: int, mxRound: int) -> Fp_Decode {
	d: Fp_Decode
	r := value
	iRound := iRound_in
	if r < 0 {
		d.sign = '-'
		r = -r
	} else if r == 0 {
		d.sign = '+'
		d.buffer[0] = '0'
		d.n = 1
		d.dp = 1
		return d
	} else {
		d.sign = '+'
	}
	v := transmute(u64)r
	e := int((v >> 52) & 0x7ff)
	if e == 0x7ff {
		d.special = v != 0x7ff0000000000000 ? 2 : 1
		if transmute(u64)value >> 63 != 0 do d.sign = '-'
		return d
	}
	v &= 0x000fffffffffffff
	if e == 0 {
		nn := fp_count_leading_zeros(v)
		v <<= uint(nn)
		e = -1074 - nn
	} else {
		v = (v << 11) | (u64(1) << 63)
		e -= 1086
	}
	digits_wanted := (iRound <= 0 || iRound >= 18) ? 18 : iRound + 1
	exp: int
	v, exp = fp2_convert10(v, e, digits_wanted)
	// The digits, right-aligned in the buffer with one slot spare in front for
	// a carry.
	i := 20
	for v > 0 {
		i -= 1
		d.buffer[i] = u8(v % 10) + '0'
		v /= 10
	}
	n := 20 - i
	d.dp = n + exp
	if iRound <= 0 {
		iRound = d.dp - iRound
		if iRound == 0 && d.buffer[i] >= '5' {
			iRound = 1
			i -= 1
			d.buffer[i] = '0'
			n += 1
			d.dp += 1
		}
	}
	d.start = i
	if iRound > 0 && (iRound < n || n > mxRound) {
		if iRound > mxRound do iRound = mxRound
		if iRound == 17 {
			// "%!.17g": fewer digits when they read back as the same double, so
			// 49.47 is not 49.469999999999999.
			if fp_digit(&d, 15) == '9' && fp_digit(&d, 14) == '9' {
				jj := 14
				for jj > 0 && fp_digit(&d, jj - 1) == '9' do jj -= 1
				v2: u64
				if jj == 0 {
					v2 = 1
				} else {
					v2 = u64(fp_digit(&d, 0) - '0')
					for kk in 1 ..< jj do v2 = v2 * 10 + u64(fp_digit(&d, kk) - '0')
					v2 += 1
				}
				if r == fp10_convert2(v2, exp + n - jj) do iRound = jj + 1
			} else if d.dp >= n || (fp_digit(&d, 15) == '0' && fp_digit(&d, 14) == '0' && fp_digit(&d, 13) == '0') {
				jj := 13
				for fp_digit(&d, jj - 1) == '0' do jj -= 1
				v2 := u64(fp_digit(&d, 0) - '0')
				for kk in 1 ..< jj do v2 = v2 * 10 + u64(fp_digit(&d, kk) - '0')
				if r == fp10_convert2(v2, exp + n - jj) do iRound = jj + 1
			}
		}
		n = iRound
		if fp_digit(&d, iRound) >= '5' {
			j := iRound - 1
			for {
				d.buffer[d.start + j] += 1
				if d.buffer[d.start + j] <= '9' do break
				d.buffer[d.start + j] = '0'
				if j == 0 {
					d.start -= 1
					d.buffer[d.start] = '1'
					n += 1
					d.dp += 1
					break
				}
				j -= 1
			}
		}
	}
	for n > 1 && fp_digit(&d, n - 1) == '0' do n -= 1
	d.n = n
	return d
}


// sqlite_format_double renders a double as SQLite's printf does for %f, %e,
// %E, %g and %G with the flags given: the text without the width's padding,
// the sign it starts with, and whether padding goes between the sign and the
// digits (zero padding) rather than before them.
sqlite_format_double :: proc(
	conversion: u8,
	r: f64,
	prefix_flag: u8,
	thousands: bool,
	alternate: bool,
	alt2: bool,
	zero: bool,
	precision: int,
	alloc: mem.Allocator,
) -> (text: []u8, sign: u8, zero_pad: bool) {
	precision := precision
	if precision < 0 do precision = 6
	if precision > 100_000_000 do precision = 100_000_000
	kind := conversion
	iRound: int
	switch kind {
	case 'f':
		iRound = -precision
	case 'g', 'G':
		if precision == 0 do precision = 1
		iRound = precision
	case:
		iRound = precision + 1
	}
	d := fp_decode(r, iRound, alt2 ? 20 : 16)
	out := make([dynamic]u8, 0, 64, alloc)
	prefix: u8 = 0
	if d.special != 0 {
		if d.special == 2 {
			append(&out, ..transmute([]u8)string(zero ? "null" : "NaN"))
			return out[:], 0, false
		}
		if zero {
			// A zero-padded infinity is written as the largest number.
			d.start = 0
			d.buffer[0] = '9'
			d.dp = 1000
			d.n = 1
			d.special = 0
		} else {
			if d.sign == '-' {
				append(&out, ..transmute([]u8)string("-Inf"))
			} else {
				if prefix_flag != 0 do append(&out, prefix_flag)
				append(&out, ..transmute([]u8)string("Inf"))
			}
			return out[:], 0, false
		}
	}
	if d.sign == '-' {
		if alternate && prefix_flag == 0 && kind == 'f' && d.dp <= iRound {
			prefix = 0
		} else {
			prefix = '-'
		}
	} else {
		prefix = prefix_flag
	}
	exp := d.dp - 1
	rtz: bool
	charset := kind == 'E' || kind == 'G' ? 'E' : 'e'
	if kind == 'g' || kind == 'G' {
		precision -= 1
		rtz = !alternate
		if exp < -4 || exp > precision {
			kind = 'e'
		} else {
			precision -= exp
			kind = 'f'
		}
	} else {
		if kind == 'E' do kind = 'e'
		rtz = alt2
	}
	e2 := kind == 'e' ? 0 : d.dp - 1
	dp_flag := precision > 0 || alternate || alt2
	if prefix != 0 do append(&out, prefix)
	j := 0
	if e2 < 0 {
		append(&out, '0')
	} else if thousands {
		for ; e2 >= 0; e2 -= 1 {
			append(&out, j < d.n ? fp_digit(&d, j) : '0')
			if j < d.n do j += 1
			if e2 % 3 == 0 && e2 > 1 do append(&out, ',')
		}
	} else {
		j = min(e2 + 1, d.n)
		append(&out, ..d.buffer[d.start:d.start + j])
		e2 -= j
		for ; e2 >= 0; e2 -= 1 do append(&out, '0')
		e2 = -1
	}
	if dp_flag do append(&out, '.')
	if e2 < -1 && precision > 0 {
		nn := min(-1 - e2, precision)
		for _ in 0 ..< nn do append(&out, '0')
		precision -= nn
	}
	if precision > 0 {
		nn := min(d.n - j, precision)
		if nn > 0 {
			append(&out, ..d.buffer[d.start + j:d.start + j + nn])
			precision -= nn
		}
		if precision > 0 && !rtz do for _ in 0 ..< precision do append(&out, '0')
	}
	if rtz && dp_flag {
		for len(out) > 0 && out[len(out) - 1] == '0' do pop(&out)
		if len(out) > 0 && out[len(out) - 1] == '.' {
			if alt2 {
				append(&out, '0')
			} else {
				pop(&out)
			}
		}
	}
	if kind == 'e' {
		e := d.dp - 1
		append(&out, u8(charset))
		if e < 0 {
			append(&out, '-')
			e = -e
		} else {
			append(&out, '+')
		}
		if e >= 100 {
			append(&out, u8(e / 100) + '0')
			e %= 100
		}
		append(&out, u8(e / 10) + '0', u8(e % 10) + '0')
	}
	return out[:], prefix, zero
}

