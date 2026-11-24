#if defined _fn_audit_included
	#endinput
#endif
#define _fn_audit_included

/* fn_audit natives (library fn_audit). Guard calls with LibraryExists check. */
native fn_case_new(admin, out[], len);
native fn_confirm_request(admin, const case_id[], const what[], minutes, const steam[], const ip[], const reason[]);
native fn_confirm_do(admin, const case_id[], steam[], steamlen, ip[], iplen, minutes[], minuteslen, reason[], reasonlen);
native fn_case_note(admin, const case_id[], const note[]);