/*
 * Copyright (C) 2003-2004 by the gtk2-perl team (see the file AUTHORS for
 * the full list)
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Library General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at your
 * option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Library General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; if not, write to the Free Software Foundation,
 * Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307  USA.
 *
 * $Header$
 */

=head2 Miscellaneous

Various useful utilities defined in Glib.xs.

=over

=cut


#include "gperl.h"

#include "ppport.h"


=item GPERL_CALL_BOOT(name)

call the boot code of a module by symbol rather than by name.

in a perl extension which uses several xs files but only one pm, you
need to bootstrap the other xs files in order to get their functions
exported to perl.  if the file has MODULE = Foo::Bar, the boot symbol
would be boot_Foo__Bar.

=item void _gperl_call_XS (pTHX_ void (*subaddr) (pTHX_ CV *), CV * cv, SV ** mark);

never use this function directly.  see C<GPERL_CALL_BOOT>.

for the curious, this calls a perl sub by function pointer rather than
by name; call_sv requires that the xsub already be registered, but we
need this to call a function which will register xsubs.  this is an
evil hack and should not be used outside of the GPERL_CALL_BOOT macro.
it's implemented as a function to avoid code size bloat, and exported
so that extension modules can pull the same trick.

=cut
void
_gperl_call_XS (pTHX_ void (*subaddr) (pTHX_ CV *), CV * cv, SV ** mark)
{
	dSP;
	PUSHMARK (mark);
	(*subaddr) (aTHX_ cv);
	PUTBACK;	/* forget return values */
}


=item gpointer gperl_alloc_temp (int nbytes)

Allocate and return a pointer to an I<nbytes>-long temporary buffer that will
be reaped at the next garbage collection sweep.  This is handy for allocating
things that need to be alloc'ed before a croak (since croak doesn't return and
give you the chance to free them).  The trick is that the memory is allocated
in a mortal perl scalar.  See the perl online manual for notes on using this
technique.

Do B<not> under any circumstances attempt to call g_free(), free(), or any other deallocator on this pointer, or you will crash the interpreter.

=cut
/*
 * taken from pgtk_alloc_temp in Gtk-Perl-0.7008/Gtk/MiscTypes.c
 */
gpointer
gperl_alloc_temp (int nbytes)
{
	dTHR;
	SV * s;

	g_return_val_if_fail (nbytes > 0, NULL);

	s = sv_2mortal (NEWSV (0, nbytes));
	memset (SvPVX (s), 0, nbytes);
	return SvPVX (s);
}

=item gchar *gperl_filename_from_sv (SV *sv)

Return a localized version of the filename in the sv, using
g_filename_from_utf8 (and consequently this function might croak). The
memory is allocated using gperl_alloc_temp.

=cut
gchar *
gperl_filename_from_sv (SV *sv)
{
        dTHR;

        GError *error = NULL;
        gchar *lname;
        STRLEN len;
        gchar *filename = SvPVutf8 (sv, len);

	/* look out: len is the length of the input when we call, but
	 * will be the length of the output when this call finishes. */
        lname = g_filename_from_utf8 (filename, len, 0, &len, &error);
        if (!lname)
        	gperl_croak_gerror (NULL, error);

        filename = gperl_alloc_temp (len + 1);
        memcpy (filename, lname, len);
        g_free (lname);

        return filename;
}

=item SV *gperl_sv_from_filename (const gchar *filename)

Convert the filename into an utf8 string as used by gtk/glib and perl.

=cut
SV *
gperl_sv_from_filename (const gchar *filename)
{
	GError *error = NULL;
        SV *sv;
	gssize len;
        gchar *str = g_filename_to_utf8 (filename, -1, NULL, &len, &error);

        if (!str)
        	gperl_croak_gerror (NULL, error);

        sv = newSVpv (str, len);
        g_free (str);

        SvUTF8_on (sv);
        return sv;
}

=item gboolean gperl_str_eq (const char * a, const char * b);

Compare a pair of ascii strings, considering '-' and '_' to be equivalent.
Used for things like enum value nicknames and signal names.

=cut
gboolean
gperl_str_eq (const char * a,
              const char * b)
{
	while (*a && *b) {
		if (*a == *b ||
		    ((*a == '-' || *a == '_') && (*b == '-' || *b == '_'))) {
			a++;
			b++;
		} else
			return FALSE;
	}
	return *a == *b;
}

=item guint gperl_str_hash (gconstpointer key)

Like g_str_hash(), but considers '-' and '_' to be equivalent.

=cut
guint
gperl_str_hash (gconstpointer key)
{
	const char *p = key;
	guint h = *p;

	if (h)
		for (p += 1; *p != '\0'; p++)
			h = (h << 5) - h + (*p == '-' ? '_' : *p);

	return h;
}

=item GPerlArgv * gperl_argv_new ()

Creates a new Perl argv object whose members can then be passed to functions
that request argc and argv style arguments.

If the called function(s) modified argv, you can call L<gperl_argv_update> to
update Perl's @ARGV in the same way.

Remember to call L<gperl_argv_free> when you're done.

=cut
GPerlArgv*
gperl_argv_new ()
{
	AV * ARGV;
	SV * ARGV0;
	int len, i;
	GPerlArgv *pargv;

	pargv = g_new (GPerlArgv, 1);

	/*
	 * heavily borrowed from gtk-perl.
	 *
	 * given the way perl handles the refcounts on SVs and the strings
	 * to which they point, i'm not certain that the g_strdup'ing of
	 * the string values is entirely necessary; however, this compiles
	 * and runs and doesn't appear either to leak or segfault, so i'll
	 * leave it.
	 */

	ARGV = get_av ("ARGV", FALSE);
	ARGV0 = get_sv ("0", FALSE);

	/* 
	 * construct the argv argument... we'll have to prepend @ARGV with $0
	 * to make it look real.  an important wrinkle: client code may strip
	 * arguments it processes without freeing them (argv is statically
	 * allocated in conventional usage).  thus, we need to keep a shadow
	 * copy of argv so we can keep from leaking the stripped strings.
	 */

	len = av_len (ARGV) + 1;

	pargv->argc = len + 1;
	pargv->shadow = g_new0 (char*, pargv->argc);
	pargv->argv = g_new0 (char*, pargv->argc);

	pargv->argv[0] = SvPV_nolen (ARGV0);

	for (i = 0 ; i < len ; i++) {
		SV ** sv = av_fetch (ARGV, i, 0);
		if (sv && SvOK (*sv))
			pargv->shadow[i] = pargv->argv[i+1]
			                 = g_strdup (SvPV_nolen (*sv));
	}

	return pargv;
}

=item void gperl_argv_update (GPerlArgv *pargv)

Updates @ARGV to resemble the stored argv array.

=cut
void
gperl_argv_update (GPerlArgv *pargv)
{
	AV * ARGV;
	int i;

	ARGV = get_av ("ARGV", FALSE);

	/* clear and refill @ARGV with whatever gtk_init didn't steal. */
	av_clear (ARGV);
	for (i = 1 ; i < pargv->argc ; i++)
		av_push (ARGV, newSVpv (pargv->argv[i], 0));
}

=item void gperl_argv_free (GPerlArgv *pargv)

Frees any resources associated with I<pargv>.

=cut
void
gperl_argv_free (GPerlArgv *pargv)
{
	g_strfreev (pargv->shadow);
	g_free (pargv->argv);
	g_free (pargv);
}

=back

=cut

MODULE = Glib		PACKAGE = Glib

BOOT:
	g_type_init ();
#if defined(G_THREADS_ENABLED) && !defined(GPERL_DISABLE_THREADSAFE)
	/*warn ("calling g_thread_init (NULL)");*/
	if (!g_thread_supported ())
		g_thread_init (NULL);
#endif
	/* boot all in one go.  other modules may not want to do it this
	 * way, if they prefer instead to perform demand loading. */
	GPERL_CALL_BOOT (boot_Glib__Utils);
	GPERL_CALL_BOOT (boot_Glib__Error);
	GPERL_CALL_BOOT (boot_Glib__Log);
	GPERL_CALL_BOOT (boot_Glib__Type);
	GPERL_CALL_BOOT (boot_Glib__Boxed);
	GPERL_CALL_BOOT (boot_Glib__Object);
	GPERL_CALL_BOOT (boot_Glib__Signal);
	GPERL_CALL_BOOT (boot_Glib__Closure);
	GPERL_CALL_BOOT (boot_Glib__MainLoop);
	GPERL_CALL_BOOT (boot_Glib__ParamSpec);
	GPERL_CALL_BOOT (boot_Glib__IO__Channel);
	/* make sure that we're running/linked against a version at least as 
	 * new as we built against, otherwise bad things will happen. */
	if ((((int)glib_major_version) < GLIB_MAJOR_VERSION)
	    ||
	    (glib_major_version == GLIB_MAJOR_VERSION && 
	     ((int)glib_minor_version) < GLIB_MINOR_VERSION)
	    ||
	    (glib_major_version == GLIB_MAJOR_VERSION && 
	     glib_minor_version == GLIB_MINOR_VERSION &&
	     ((int)glib_micro_version) < GLIB_MICRO_VERSION))
		warn ("*** This build of Glib was compiled with glib %d.%d.%d,"
		      " but is currently running with %d.%d.%d, which is too"
		      " old.  We'll continue, but expect problems!\n",
		    GLIB_MAJOR_VERSION, GLIB_MINOR_VERSION, GLIB_MICRO_VERSION,
		    glib_major_version, glib_minor_version, glib_micro_version);

##
## NOTE: in order to avoid overwriting the docs for the main Glib.pm, 
##       all xsubs in this section must be either assigned to other
##       packages or marked as hidden.
##

=for apidoc __hide__
=cut
const char *
filename_from_unicode (class_or_filename, filename=NULL)
	GPerlFilename_const class_or_filename
	GPerlFilename_const filename
    PROTOTYPE: $
    CODE:
	RETVAL = items < 2 ? class_or_filename : filename;
    OUTPUT:
        RETVAL

=for apidoc __hide__
=cut
GPerlFilename_const
filename_to_unicode (const char * class_or_filename, const char *filename=NULL)
    PROTOTYPE: $
    CODE:
	RETVAL = items < 2 ? class_or_filename : filename;
    OUTPUT:
        RETVAL

=for apidoc __hide__
=cut
void
filename_from_uri (...)
    PROTOTYPE: $
    PREINIT:
	gchar * filename;
	const char * uri;
	char * hostname;
	GError * error = NULL;
    PPCODE:
	/* support multiple call syntaxes. */
	//uri = items < 2 ? SvGChar (ST (0)) : SvGChar (ST (1));
	uri = items < 2 ? SvPVutf8_nolen (ST (0)) : SvPVutf8_nolen (ST (1));
	filename = g_filename_from_uri (uri,
	                                GIMME_V == G_ARRAY ? &hostname : NULL, 
	                                &error);
	if (!filename)
		gperl_croak_gerror (NULL, error);
	PUSHs (sv_2mortal (newSVpv (filename, 0)));
	if (GIMME_V == G_ARRAY && hostname)
		XPUSHs (sv_2mortal (newSVpv (hostname, 0)));
	g_free (filename);
	if (hostname) g_free (hostname);

=for apidoc __hide__
=cut
gchar_own *
filename_to_uri (...)
    PROTOTYPE: $$
    PREINIT:
	char * filename = NULL;
	char * hostname = NULL;
	GError * error = NULL;
    CODE:
	// FIXME FIXME this is broken somehow
	if (items == 2) {
		filename = SvPV_nolen (ST (0));
		hostname = SvOK (ST (1)) ? SvPV_nolen (ST (1)) : NULL;
	} else if (items == 3) {
		filename = SvPV_nolen (ST (1));
		hostname = SvOK (ST (2)) ? SvPV_nolen (ST (2)) : NULL;
	} else {
		croak ("Usage: Glib::filename_to_uri (filename, hostname)\n"
		       " -or-  Glib->filename_to_uri (filename, hostname)\n"
		       "  wrong number of arguments");
	}
	RETVAL = g_filename_to_uri (filename, hostname, &error);
	if (!RETVAL)
		gperl_croak_gerror (NULL, error);
    OUTPUT:
	RETVAL
