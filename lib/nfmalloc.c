/*
 * libdpkg - Debian packaging suite library routines
 * nfmalloc.c - non-freeing malloc, used for in-core database
 *
 * Copyright (C) 1994,1995 Ian Jackson <iwj10@cus.cam.ac.uk>
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2,
 * or (at your option) any later version.
 *
 * This is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with dpkg; if not, write to the Free Software
 * Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#include <stdlib.h>
#include <string.h>

#include <config.h>
#include <dpkg.h>
#include <dpkg-db.h>

#include <obstack.h>

#define obstack_chunk_alloc m_malloc
#define obstack_chunk_free free

static struct obstack db_obs;
static int dbobs_init = 0;

/* We use lots of mem, so use a large chunk */
#define CHUNK_SIZE 8192

#define OBSTACK_INIT if (!dbobs_init) { nfobstack_init(); }

static void nfobstack_init(void) {
  obstack_init(&db_obs);
  dbobs_init = 1;
  obstack_chunk_size(&db_obs) = 8192;
}
  
#ifdef HAVE_INLINE
inline void *nfmalloc(size_t size)
#else
void *nfmalloc(size_t size)
#endif
{
  OBSTACK_INIT;
  return obstack_alloc(&db_obs, size);
}

char *nfstrsave(const char *string) {
  OBSTACK_INIT;
  return obstack_copy (&db_obs, string, strlen(string) + 1);
}

char *nfstrnsave(const char *string, int l) {
  OBSTACK_INIT;
  return obstack_copy (&db_obs, string, l);
}

void nffreeall(void) {
  obstack_free(&db_obs, 0);
  dbobs_init = 0;
}
