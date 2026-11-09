; ram-altman.asm - track RAM usage and, at most once a day, tell Sam Altman
; when this PC has RAM to spare.  FASM / Win32 port of ram-altman.sh.
;
; Build:
;   fasm ram-altman.asm          (needs INCLUDE pointing at FASM's INCLUDE dir)
;
; Usage:
;   ram-altman.exe            Log a sample and send the daily email if due
;   ram-altman.exe --status   Print current memory figures and exit
;   ram-altman.exe --dry-run  Print the email that would be sent and exit
;
; Task Scheduler (every 5 minutes):
;   schtasks /create /tn ram-altman /sc minute /mo 5 /tr "C:\path\ram-altman.exe"
;
; Settings come from environment variables (set them with setx):
;   RAM_ALTMAN_TO          Who receives the email (required)
;   RAM_ALTMAN_FROM        A real address you can send from (required)
;   RAM_ALTMAN_FROM_NAME   Display name, optional
;   RAM_ALTMAN_THRESHOLD   Email when available is above this percent (default 10)
;   RAM_ALTMAN_SMTP_URL    e.g. smtps://smtp.example.com:465 - sends with the
;                          curl.exe that ships with Windows; login comes from
;                          %USERPROFILE%\_netrc. TLS is required.
;                          Unset: falls back to sendmail.exe or msmtp.exe on PATH.
;   RAM_ALTMAN_STATE_DIR   Default %LOCALAPPDATA%\ram-altman
;
; How "used" is worked out:
;   used = total physical - available physical   (GlobalMemoryStatusEx)
;
;   Windows' "available" is the free and zeroed lists plus the standby list,
;   i.e. cached pages the memory manager can hand out straight away, so cached
;   RAM does not count as used. Modified pages that still need writing out are
;   not included. "Cache" is GetPerformanceInfo's SystemCache (standby list
;   plus system working set), capped at available; "Free" is the rest.

format PE console 4.0
entry start

include 'win32a.inc'

nl equ 13,10

MAX_LOG_BYTES     = 10*1024*1024   ; Trim the log once it passes 10 MiB
LOG_LINES_TO_KEEP = 50000

G_TOTAL = 1                        ; Placeholders in the email templates
G_AVAIL = 2
G_PCT   = 3

MODE_RUN     = 0
MODE_STATUS  = 1
MODE_DRYRUN  = 2
MODE_HELP    = 3
MODE_UNKNOWN = 4

PATH_LEN = 320
MY_MAX_PATH = 260
MY_INFINITE              = -1
MY_INVALID_HANDLE_VALUE  = -1
MY_STD_INPUT_HANDLE      = -10
MY_STD_OUTPUT_HANDLE     = -11
MY_STD_ERROR_HANDLE      = -12
MY_GENERIC_READ          = 80000000h
MY_GENERIC_WRITE         = 40000000h
MY_FILE_SHARE_READ       = 1
MY_CREATE_ALWAYS         = 2
MY_OPEN_EXISTING         = 3
MY_OPEN_ALWAYS           = 4
MY_FILE_ATTRIBUTE_NORMAL = 80h
MY_FILE_END              = 2
MY_MEM_COMMIT            = 1000h
MY_MEM_RELEASE           = 8000h
MY_PAGE_READWRITE        = 4
MY_MOVEFILE_REPLACE_EXISTING = 1
MY_ERROR_FILE_EXISTS         = 80
MY_ERROR_ALREADY_EXISTS      = 183
MY_ERROR_SHARING_VIOLATION   = 32
MY_STARTF_USESTDHANDLES      = 100h
MY_TIME_ZONE_ID_STANDARD     = 1
MY_TIME_ZONE_ID_DAYLIGHT     = 2

; =============================================================================
section '.text' code readable executable

start:
        invoke  GetStdHandle,MY_STD_OUTPUT_HANDLE
        mov     [hstdout],eax
        call    seed_random
        call    parse_args
        call    read_settings

        mov     eax,[mode]
        cmp     eax,MODE_STATUS
        je      .status
        cmp     eax,MODE_DRYRUN
        je      .dry_run
        cmp     eax,MODE_HELP
        je      .help
        cmp     eax,MODE_RUN
        je      .run
        cinvoke wsprintfA,tmpbuf,_unknown_fmt,argbuf
        stdcall die,tmpbuf

.help:
        stdcall puts,_help
        jmp     .exit0

.status:
        call    read_memory
        call    print_status
        jmp     .exit0

.dry_run:
        mov     [dry_run],1
        call    read_memory
        call    print_status
        call    is_over_threshold
        test    eax,eax
        jnz     .dry_compose
        cinvoke wsprintfA,tmpbuf,_no_email_fmt,[threshold]
        stdcall puts,tmpbuf
        jmp     .exit0
.dry_compose:
        call    compose_email
        cmp     byte [recipient],0
        jne     @f
        invoke  lstrcpyA,recipient,_default_to
@@:     cmp     byte [sender],0
        jne     @f
        invoke  lstrcpyA,sender,_default_from
@@:     stdcall puts,_crlf
        call    render_message
        stdcall puts,msgbuf
        jmp     .exit0

.run:
        cmp     byte [recipient],0
        jne     @f
        stdcall die,_err_no_to
@@:     cmp     byte [sender],0
        jne     @f
        stdcall die,_err_no_from
@@:     call    setup_state_dir

        ; Stop overlapping runs from both sending today's email: the lock
        ; file is held open without sharing until this process exits.
        invoke  CreateFileA,lock_path,MY_GENERIC_WRITE,0,0,MY_OPEN_ALWAYS,MY_FILE_ATTRIBUTE_NORMAL,0
        cmp     eax,MY_INVALID_HANDLE_VALUE
        jne     .locked
        invoke  GetLastError
        cmp     eax,MY_ERROR_SHARING_VIOLATION
        je      .exit0
        stdcall die,_err_lock
.locked:
        call    read_memory
        call    log_sample

        call    is_over_threshold
        test    eax,eax
        jz      .exit0

        call    get_time
        cinvoke wsprintfA,today,_date_fmt,[st_year],[st_month],[st_day]
        stdcall read_small,last_sent_path,lastbuf,32
        invoke  lstrlenA,lastbuf
.trim:  test    eax,eax                 ; drop trailing whitespace / newline
        jz      .compare
        cmp     byte [lastbuf+eax-1],' '
        ja      .compare
        dec     eax
        mov     byte [lastbuf+eax],0
        jmp     .trim
.compare:
        invoke  lstrcmpA,today,lastbuf
        test    eax,eax
        jz      .exit0

        call    compose_email
        call    render_message
        call    send_email
        test    eax,eax
        jz      @f
        stdcall die,_err_send
@@:
        ; Recorded only after a successful send, so a failure gets retried.
        stdcall write_file,last_sent_path,today,10
.exit0:
        invoke  ExitProcess,0

; -----------------------------------------------------------------------------
; Takes the first argument from the command line into argbuf, sets [mode].
parse_args:
        invoke  GetCommandLineA
        mov     esi,eax
        cmp     byte [esi],'"'
        jne     .unquoted
        inc     esi
.quoted:
        lodsb
        test    al,al
        jz      .back
        cmp     al,'"'
        jne     .quoted
        jmp     .skip_ws
.unquoted:
        lodsb
        test    al,al
        jz      .back
        cmp     al,' '
        je      .skip_ws
        cmp     al,9
        jne     .unquoted
        jmp     .skip_ws
.back:  dec     esi
.skip_ws:
        mov     al,[esi]
        cmp     al,' '
        je      .ws
        cmp     al,9
        jne     .copy
.ws:    inc     esi
        jmp     .skip_ws
.copy:  mov     edi,argbuf
        mov     ecx,255
.c:     mov     al,[esi]
        test    al,al
        jz      .copied
        cmp     al,' '
        je      .copied
        cmp     al,9
        je      .copied
        mov     [edi],al
        inc     esi
        inc     edi
        dec     ecx
        jnz     .c
.copied:
        mov     byte [edi],0

        mov     [mode],MODE_RUN
        cmp     byte [argbuf],0
        je      .done
        mov     [mode],MODE_STATUS
        invoke  lstrcmpA,argbuf,_opt_status
        test    eax,eax
        jz      .done
        mov     [mode],MODE_DRYRUN
        invoke  lstrcmpA,argbuf,_opt_dry_run
        test    eax,eax
        jz      .done
        mov     [mode],MODE_HELP
        invoke  lstrcmpA,argbuf,_opt_help
        test    eax,eax
        jz      .done
        invoke  lstrcmpA,argbuf,_opt_h
        test    eax,eax
        jz      .done
        mov     [mode],MODE_UNKNOWN
.done:  ret

; -----------------------------------------------------------------------------
read_settings:
        stdcall get_env,_env_to,recipient,256
        stdcall get_env,_env_from,sender,256
        stdcall get_env,_env_from_name,sender_name,256
        stdcall get_env,_env_smtp,smtp_url,512
        stdcall get_env,_env_threshold,threshold_s,16

        mov     [threshold],10
        mov     esi,threshold_s
        cmp     byte [esi],0
        je      .done
        xor     eax,eax
.digit: movzx   edx,byte [esi]
        test    edx,edx
        jz      .parsed
        sub     edx,'0'
        cmp     edx,9
        ja      .bad
        imul    eax,10
        add     eax,edx
        cmp     eax,100
        ja      .bad
        inc     esi
        jmp     .digit
.parsed:
        mov     [threshold],eax
.done:  ret
.bad:   stdcall die,_err_threshold

; -----------------------------------------------------------------------------
proc get_env ge_name, ge_buf, ge_size
        invoke  GetEnvironmentVariableA,[ge_name],[ge_buf],[ge_size]
        cmp     eax,[ge_size]
        jb      @f
        cinvoke wsprintfA,tmpbuf2,_too_long_fmt,[ge_name]
        stdcall die,tmpbuf2
@@:     test    eax,eax
        jnz     @f
        mov     edx,[ge_buf]
        mov     byte [edx],0
@@:     ret
endp

; -----------------------------------------------------------------------------
setup_state_dir:
        stdcall get_env,_env_state_dir,state_dir,PATH_LEN-32
        cmp     byte [state_dir],0
        jne     .make
        stdcall get_env,_env_localappdata,state_dir,PATH_LEN-32
        cmp     byte [state_dir],0
        jne     @f
        stdcall die,_err_no_state_dir
@@:     invoke  lstrcatA,state_dir,_dir_name
.make:  invoke  SHCreateDirectoryExA,0,state_dir,0
        test    eax,eax
        jz      .paths
        cmp     eax,MY_ERROR_ALREADY_EXISTS
        je      .paths
        cmp     eax,MY_ERROR_FILE_EXISTS
        je      .paths
        stdcall die,_err_mkdir
.paths: stdcall make_path,usage_log_path,_f_usage
        stdcall make_path,tmp_log_path,_f_usage_tmp
        stdcall make_path,last_sent_path,_f_last_sent
        stdcall make_path,lock_path,_f_lock
        stdcall make_path,msg_path,_f_message
        ret

proc make_path uses esi edi, mp_dest, mp_file
        mov     edi,[mp_dest]
        mov     esi,state_dir
        call    append
        mov     esi,[mp_file]
        call    append
        ret
endp

; -----------------------------------------------------------------------------
; Sets total_kb, avail_kb, used_kb, free_kb, cache_kb and their strings.
proc read_memory uses ebx esi edi
        invoke  GlobalMemoryStatusEx,memstat
        test    eax,eax
        jnz     @f
        stdcall die,_err_memstat
@@:     mov     eax,dword [memstat.total]
        mov     edx,dword [memstat.total+4]
        call    bytes_to_kb
        mov     [total_kb],eax
        test    eax,eax
        jnz     @f
        stdcall die,_err_memstat
@@:     mov     eax,dword [memstat.avail]
        mov     edx,dword [memstat.avail+4]
        call    bytes_to_kb
        cmp     eax,[total_kb]
        jbe     @f
        mov     eax,[total_kb]
@@:     mov     [avail_kb],eax

        xor     ebx,ebx                         ; cache_kb
        invoke  K32GetPerformanceInfo,perf,56
        test    eax,eax
        jz      @f
        mov     eax,[perf.SystemCache]
        mul     dword [perf.PageSize]
        call    bytes_to_kb
        mov     ebx,eax
@@:     cmp     ebx,[avail_kb]
        jbe     @f
        mov     ebx,[avail_kb]
@@:     mov     [cache_kb],ebx
        mov     eax,[avail_kb]
        sub     eax,ebx
        mov     [free_kb],eax
        mov     eax,[total_kb]
        sub     eax,[avail_kb]
        mov     [used_kb],eax

        ; available_pct to one decimal, rounded: avail * 1000 / total
        mov     eax,[avail_kb]
        mov     ecx,1000
        mul     ecx
        div     dword [total_kb]
        mov     ecx,[total_kb]
        sub     ecx,edx
        cmp     edx,ecx
        jb      @f
        inc     eax
@@:     xor     edx,edx
        mov     ecx,10
        div     ecx
        cinvoke wsprintfA,str_pct,_tenths_fmt,eax,edx

        stdcall fmt_gib,[total_kb],str_total
        stdcall fmt_gib,[used_kb],str_used
        stdcall fmt_gib,[avail_kb],str_avail
        stdcall fmt_gib,[free_kb],str_free
        stdcall fmt_gib,[cache_kb],str_cache
        ret
endp

; edx:eax bytes -> eax kB (saturates at 4 TiB)
bytes_to_kb:
        shrd    eax,edx,10
        shr     edx,10
        jz      @f
        or      eax,-1
@@:     ret

; "12.3 GiB"
proc fmt_gib fg_kb, fg_dest
        mov     eax,[fg_kb]
        mov     ecx,10
        mul     ecx
        add     eax,1 shl 19
        adc     edx,0
        shrd    eax,edx,20
        xor     edx,edx
        div     ecx
        cinvoke wsprintfA,[fg_dest],_gib_fmt,eax,edx
        ret
endp

is_over_threshold:                      ; eax = 1 if avail*100 > threshold*total
        push    ebx esi
        mov     eax,[avail_kb]
        mov     ecx,100
        mul     ecx
        mov     ebx,eax
        mov     esi,edx
        mov     eax,[threshold]
        mul     dword [total_kb]
        cmp     esi,edx
        ja      .yes
        jb      .no
        cmp     ebx,eax
        ja      .yes
.no:    xor     eax,eax
        pop     esi ebx
        ret
.yes:   mov     eax,1
        pop     esi ebx
        ret

print_status:
        cinvoke wsprintfA,tmpbuf,_status_fmt,str_total,str_used,str_avail,str_pct,str_free,str_cache
        stdcall puts,tmpbuf
        ret

; -----------------------------------------------------------------------------
; Local time and UTC offset into st_* / tz_*.
get_time:
        invoke  GetLocalTime,systime
        invoke  GetTimeZoneInformation,tzi
        mov     ecx,[tzi.Bias]
        cmp     eax,MY_TIME_ZONE_ID_DAYLIGHT
        jne     .std
        add     ecx,[tzi.DaylightBias]
        jmp     .bias
.std:   cmp     eax,MY_TIME_ZONE_ID_STANDARD
        jne     .bias
        add     ecx,[tzi.StandardBias]
.bias:  neg     ecx                     ; offset = -bias
        mov     [tz_sign],'+'
        jns     @f
        mov     [tz_sign],'-'
        neg     ecx
@@:     mov     eax,ecx
        xor     edx,edx
        mov     ecx,60
        div     ecx
        mov     [tz_h],eax
        mov     [tz_m],edx
        movzx   eax,[systime.wYear]
        mov     [st_year],eax
        movzx   eax,[systime.wMonth]
        mov     [st_month],eax
        movzx   eax,[systime.wDayOfWeek]
        mov     [st_dow],eax
        movzx   eax,[systime.wDay]
        mov     [st_day],eax
        movzx   eax,[systime.wHour]
        mov     [st_hour],eax
        movzx   eax,[systime.wMinute]
        mov     [st_min],eax
        movzx   eax,[systime.wSecond]
        mov     [st_sec],eax
        ret

; -----------------------------------------------------------------------------
proc log_sample uses ebx
        invoke  CreateFileA,usage_log_path,MY_GENERIC_WRITE,MY_FILE_SHARE_READ,0,MY_OPEN_ALWAYS,MY_FILE_ATTRIBUTE_NORMAL,0
        cmp     eax,MY_INVALID_HANDLE_VALUE
        jne     @f
        stdcall die,_err_log
@@:     mov     ebx,eax
        invoke  GetLastError
        cmp     eax,MY_ERROR_ALREADY_EXISTS
        je      @f
        stdcall write_h,ebx,_csv_header
@@:     invoke  SetFilePointer,ebx,0,0,MY_FILE_END
        call    get_time
        cinvoke wsprintfA,isobuf,_iso_fmt,[st_year],[st_month],[st_day],[st_hour],[st_min],[st_sec],[tz_sign],[tz_h],[tz_m]
        cinvoke wsprintfA,tmpbuf,_csv_fmt,isobuf,[total_kb],[used_kb],[avail_kb],str_pct
        stdcall write_h,ebx,tmpbuf
        invoke  GetFileSize,ebx,0
        push    eax
        invoke  CloseHandle,ebx
        pop     eax
        cmp     eax,MAX_LOG_BYTES
        jbe     @f
        call    trim_log
@@:     ret
endp

; Keeps the header line plus the last LOG_LINES_TO_KEEP lines.
proc trim_log uses ebx esi edi
        invoke  CreateFileA,usage_log_path,MY_GENERIC_READ,MY_FILE_SHARE_READ,0,MY_OPEN_EXISTING,MY_FILE_ATTRIBUTE_NORMAL,0
        cmp     eax,MY_INVALID_HANDLE_VALUE
        je      .done
        mov     ebx,eax
        invoke  GetFileSize,ebx,0
        mov     [tl_size],eax
        invoke  VirtualAlloc,0,eax,MY_MEM_COMMIT,MY_PAGE_READWRITE
        mov     [tl_buf],eax
        test    eax,eax
        jz      .close
        invoke  ReadFile,ebx,[tl_buf],[tl_size],nread,0
        mov     esi,eax
        invoke  CloseHandle,ebx
        test    esi,esi
        jz      .free
        mov     eax,[nread]
        mov     [tl_size],eax
        test    eax,eax
        jz      .free

        mov     edi,[tl_buf]            ; header = up to and including first LF
        mov     ecx,eax
        mov     al,10
        repne   scasb
        mov     eax,edi
        sub     eax,[tl_buf]
        mov     [tl_hdr],eax

        mov     esi,[tl_buf]            ; walk back over LOG_LINES_TO_KEEP lines
        mov     ecx,[tl_size]
        cmp     byte [esi+ecx-1],10
        jne     @f
        dec     ecx
@@:     xor     edx,edx
.scan:  test    ecx,ecx
        jz      .got
        dec     ecx
        cmp     byte [esi+ecx],10
        jne     .scan
        inc     edx
        cmp     edx,LOG_LINES_TO_KEEP
        jne     .scan
        inc     ecx
.got:   mov     [tl_start],ecx

        invoke  CreateFileA,tmp_log_path,MY_GENERIC_WRITE,0,0,MY_CREATE_ALWAYS,MY_FILE_ATTRIBUTE_NORMAL,0
        cmp     eax,MY_INVALID_HANDLE_VALUE
        je      .free
        mov     ebx,eax
        invoke  WriteFile,ebx,[tl_buf],[tl_hdr],nwritten,0
        mov     esi,eax
        mov     eax,[tl_buf]
        add     eax,[tl_start]
        mov     ecx,[tl_size]
        sub     ecx,[tl_start]
        invoke  WriteFile,ebx,eax,ecx,nwritten,0
        and     esi,eax
        invoke  CloseHandle,ebx
        test    esi,esi
        jz      .free
        invoke  MoveFileExA,tmp_log_path,usage_log_path,MY_MOVEFILE_REPLACE_EXISTING
.free:  invoke  VirtualFree,[tl_buf],0,MY_MEM_RELEASE
.done:  ret
.close: invoke  CloseHandle,ebx
        ret
endp

; -----------------------------------------------------------------------------
; Deals out every option once, in random order, before any can come up again.
; Returns an index from 0 to count-1 (count <= 10: the bag stores one digit
; per option). A dry run changes nothing on disk.
proc pick uses ebx esi edi, pk_name, pk_count
        mov     ecx,[pk_count]
        cmp     [dry_run],0
        je      .disk
        call    rand_below
        ret
.disk:
        mov     edi,bag_path
        mov     esi,state_dir
        call    append
        mov     esi,_bag_prefix
        call    append
        mov     esi,[pk_name]
        call    append
        mov     edi,bag_last_path
        mov     esi,bag_path
        call    append
        mov     esi,_dot_last
        call    append

        stdcall read_small,bag_path,bagbuf,64
        mov     esi,bagbuf              ; keep digits only
        mov     edi,bagbuf
.filter:
        lodsb
        test    al,al
        jz      .filtered
        cmp     al,'0'
        jb      .filter
        cmp     al,'9'
        ja      .filter
        stosb
        jmp     .filter
.filtered:
        mov     byte [edi],0
        mov     ebx,edi
        sub     ebx,bagbuf              ; ebx = cards left
        jnz     .deal_one

        mov     ebx,[pk_count]          ; new round: 0..count-1, shuffled
        xor     ecx,ecx
.fill:  lea     eax,[ecx+'0']
        mov     [bagbuf+ecx],al
        inc     ecx
        cmp     ecx,ebx
        jb      .fill
        mov     byte [bagbuf+ebx],0
        mov     edi,ebx
.shuffle:                               ; Fisher-Yates
        dec     edi
        jz      .shuffled
        lea     ecx,[edi+1]
        call    rand_below
        mov     dl,[bagbuf+edi]
        mov     dh,[bagbuf+eax]
        mov     [bagbuf+edi],dh
        mov     [bagbuf+eax],dl
        jmp     .shuffle
.shuffled:
        ; Stop the last pick of the old round opening the new one.
        cmp     ebx,1
        jbe     .deal_one
        stdcall read_small,bag_last_path,bag_lastc,8
        mov     al,[bag_lastc]
        cmp     al,[bagbuf]
        jne     .deal_one
        mov     dl,[bagbuf]
        xor     ecx,ecx
.rotate:
        mov     al,[bagbuf+ecx+1]
        mov     [bagbuf+ecx],al
        inc     ecx
        cmp     ecx,ebx
        jb      .rotate
        mov     [bagbuf+ebx-1],dl

.deal_one:
        movzx   edi,byte [bagbuf]
        sub     edi,'0'
        lea     eax,[ebx-1]
        stdcall write_file,bag_path,bagbuf+1,eax
        stdcall write_file,bag_last_path,bagbuf,1
        ; Covers the template lists being shortened after the bag was dealt.
        cmp     edi,[pk_count]
        jb      @f
        mov     ecx,[pk_count]
        call    rand_below
        mov     edi,eax
@@:     mov     eax,edi
        ret
endp

; -----------------------------------------------------------------------------
proc compose_email uses ebx esi edi
        stdcall pick,_name_subject,SUBJECT_COUNT
        mov     esi,[subjects+eax*4]
        mov     edi,email_subject
        call    expand
        stdcall pick,_name_body,BODY_COUNT
        mov     ebx,eax
        stdcall pick,_name_signoff,SIGNOFF_COUNT
        push    eax

        mov     edi,email_body
        mov     esi,_hi_sam
        call    append
        mov     esi,[bodies+ebx*4]
        call    expand
        mov     esi,_two_nl
        call    append
        pop     eax
        mov     esi,[signoffs+eax*4]
        call    append
        mov     esi,_crlf
        call    append
        mov     esi,sender_name
        cmp     byte [esi],0
        jne     @f
        mov     esi,_default_name
@@:     call    append
        mov     esi,_footer
        call    append
        ret
endp

proc render_message uses esi edi
        call    get_time
        mov     eax,[st_dow]
        mov     eax,[day_names+eax*4]
        mov     edx,[st_month]
        mov     edx,[month_names+edx*4-4]
        cinvoke wsprintfA,datebuf,_rfc_fmt,eax,[st_day],edx,[st_year],[st_hour],[st_min],[st_sec],[tz_sign],[tz_h],[tz_m]

        mov     edi,msgbuf
        mov     esi,_h_from
        call    append
        cmp     byte [sender_name],0
        je      .plain
        mov     esi,sender_name
        call    append
        mov     esi,_lt
        call    append
        mov     esi,sender
        call    append
        mov     esi,_gt
        call    append
        jmp     .to
.plain: mov     esi,sender
        call    append
.to:    mov     esi,_h_to
        call    append
        mov     esi,recipient
        call    append
        mov     esi,_h_subject
        call    append
        mov     esi,email_subject
        call    append
        mov     esi,_h_date
        call    append
        mov     esi,datebuf
        call    append
        mov     esi,_h_rest
        call    append
        mov     esi,email_body
        call    append
        mov     esi,_crlf
        call    append
        ret
endp

; Returns eax = 0 on success.
proc send_email uses ebx esi edi
        invoke  lstrlenA,msgbuf
        stdcall write_file,msg_path,msgbuf,eax
        test    eax,eax
        jz      .fail

        cmp     byte [smtp_url],0
        je      .local

        invoke  GetSystemDirectoryA,app_path,MY_MAX_PATH
        test    eax,eax
        jz      .fail
        invoke  lstrcatA,app_path,_curl_exe
        mov     edi,cmdline
        mov     esi,_q
        call    append
        mov     esi,app_path
        call    append
        mov     esi,_curl_args1
        call    append
        mov     esi,smtp_url
        call    append
        mov     esi,_curl_args2
        call    append
        mov     esi,sender
        call    append
        mov     esi,_curl_args3
        call    append
        mov     esi,recipient
        call    append
        mov     esi,_curl_args4
        call    append
        mov     esi,msg_path
        call    append
        mov     esi,_q
        call    append
        stdcall run_process,0
        jmp     .sent

.local: invoke  SearchPathA,0,_sendmail_exe,0,MY_MAX_PATH,app_path,0
        mov     ebx,_sendmail_args
        test    eax,eax
        jz      .msmtp
        cmp     eax,MY_MAX_PATH
        jb      .found
.msmtp: invoke  SearchPathA,0,_msmtp_exe,0,MY_MAX_PATH,app_path,0
        mov     ebx,_msmtp_args
        test    eax,eax
        jz      .none
        cmp     eax,MY_MAX_PATH
        jae     .none
.found: mov     edi,cmdline
        mov     esi,_q
        call    append
        mov     esi,app_path
        call    append
        mov     esi,_q
        call    append
        mov     esi,ebx
        call    append
        invoke  CreateFileA,msg_path,MY_GENERIC_READ,MY_FILE_SHARE_READ,sa_inherit,MY_OPEN_EXISTING,MY_FILE_ATTRIBUTE_NORMAL,0
        cmp     eax,MY_INVALID_HANDLE_VALUE
        je      .fail
        mov     ebx,eax
        stdcall run_process,ebx
        mov     esi,eax
        invoke  CloseHandle,ebx
        mov     eax,esi
.sent:  push    eax
        invoke  DeleteFileA,msg_path
        pop     eax
        ret
.none:  invoke  GetStdHandle,MY_STD_ERROR_HANDLE
        stdcall write_h,eax,_err_no_mailer
.fail:  or      eax,-1
        ret
endp

; Runs app_path with cmdline; rp_stdin = handle for its stdin, or 0.
; Returns the exit code, or -1 if it could not be started.
proc run_process rp_stdin
        mov     eax,[rp_stdin]
        test    eax,eax
        jnz     @f
        invoke  GetStdHandle,MY_STD_INPUT_HANDLE
@@:     mov     [sinfo.hStdInput],eax
        invoke  GetStdHandle,MY_STD_OUTPUT_HANDLE
        mov     [sinfo.hStdOutput],eax
        invoke  GetStdHandle,MY_STD_ERROR_HANDLE
        mov     [sinfo.hStdError],eax
        invoke  CreateProcessA,app_path,cmdline,0,0,1,0,0,0,sinfo,pinfo
        test    eax,eax
        jnz     @f
        or      eax,-1
        ret
@@:     invoke  WaitForSingleObject,[pinfo.hProcess],MY_INFINITE
        invoke  GetExitCodeProcess,[pinfo.hProcess],exitcode
        invoke  CloseHandle,[pinfo.hThread]
        invoke  CloseHandle,[pinfo.hProcess]
        mov     eax,[exitcode]
        ret
endp

; -----------------------------------------------------------------------------
; String helpers. esi = source (zero-terminated), edi = destination cursor.
; Both leave edi on the terminating zero so calls can be chained.
append:
        lodsb
        stosb
        test    al,al
        jnz     append
        dec     edi
        ret

expand:                                 ; append, filling in G_* placeholders
        lodsb
        cmp     al,G_TOTAL
        je      .total
        cmp     al,G_AVAIL
        je      .avail
        cmp     al,G_PCT
        je      .pct
        stosb
        test    al,al
        jnz     expand
        dec     edi
        ret
.total: push    esi
        mov     esi,str_total
        jmp     .insert
.avail: push    esi
        mov     esi,str_avail
        jmp     .insert
.pct:   push    esi
        mov     esi,str_pct
.insert:
        call    append
        pop     esi
        jmp     expand

; Reads up to rs_max-1 bytes, zero-terminated. Returns bytes read (0 if missing).
proc read_small uses ebx, rs_path, rs_buf, rs_max
        mov     edx,[rs_buf]
        mov     byte [edx],0
        mov     [nread],0
        invoke  CreateFileA,[rs_path],MY_GENERIC_READ,MY_FILE_SHARE_READ,0,MY_OPEN_EXISTING,MY_FILE_ATTRIBUTE_NORMAL,0
        cmp     eax,MY_INVALID_HANDLE_VALUE
        je      .done
        mov     ebx,eax
        mov     ecx,[rs_max]
        dec     ecx
        invoke  ReadFile,ebx,[rs_buf],ecx,nread,0
        test    eax,eax
        jnz     @f
        mov     [nread],0
@@:     invoke  CloseHandle,ebx
.done:  mov     eax,[nread]
        mov     edx,[rs_buf]
        mov     byte [edx+eax],0
        ret
endp

; Returns eax nonzero on success.
proc write_file uses ebx esi, wf_path, wf_buf, wf_len
        invoke  CreateFileA,[wf_path],MY_GENERIC_WRITE,0,0,MY_CREATE_ALWAYS,MY_FILE_ATTRIBUTE_NORMAL,0
        cmp     eax,MY_INVALID_HANDLE_VALUE
        jne     @f
        xor     eax,eax
        ret
@@:     mov     ebx,eax
        invoke  WriteFile,ebx,[wf_buf],[wf_len],nwritten,0
        mov     esi,eax
        invoke  CloseHandle,ebx
        mov     eax,esi
        ret
endp

proc write_h wh_handle, wh_str
        invoke  lstrlenA,[wh_str]
        invoke  WriteFile,[wh_handle],[wh_str],eax,nwritten,0
        ret
endp

proc puts p_str
        stdcall write_h,[hstdout],[p_str]
        ret
endp

proc die d_msg
        invoke  GetStdHandle,MY_STD_ERROR_HANDLE
        mov     ebx,eax
        stdcall write_h,ebx,_prefix
        stdcall write_h,ebx,[d_msg]
        stdcall write_h,ebx,_crlf
        invoke  ExitProcess,1
endp

; -----------------------------------------------------------------------------
; xorshift32
seed_random:
        push    ebx
        rdtsc
        mov     ebx,eax
        invoke  GetTickCount
        xor     ebx,eax
        invoke  GetCurrentProcessId
        shl     eax,16
        xor     ebx,eax
        jnz     @f
        inc     ebx
@@:     mov     [seed],ebx
        pop     ebx
        ret

rand:
        mov     eax,[seed]
        mov     edx,eax
        shl     edx,13
        xor     eax,edx
        mov     edx,eax
        shr     edx,17
        xor     eax,edx
        mov     edx,eax
        shl     edx,5
        xor     eax,edx
        mov     [seed],eax
        ret

rand_below:                             ; ecx = n, returns eax in [0, n)
        call    rand
        xor     edx,edx
        div     ecx
        mov     eax,edx
        ret

; =============================================================================
section '.data' data readable writeable

_help   db 'ram-altman.exe - track RAM usage and, at most once a day, tell Sam Altman',nl
        db 'when this PC has RAM to spare.',nl,nl
        db 'Usage:',nl
        db '  ram-altman.exe            Log a sample and send the daily email if due',nl
        db '  ram-altman.exe --status   Print current memory figures and exit',nl
        db '  ram-altman.exe --dry-run  Print the email that would be sent and exit',nl,nl
        db 'Task Scheduler (every 5 minutes):',nl
        db '  schtasks /create /tn ram-altman /sc minute /mo 5 /tr "C:\path\ram-altman.exe"',nl,0

; ----- Email templates --------------------------------------------------------
subjects dd s0,s1,s2,s3,s4,s5,s6,s7
SUBJECT_COUNT = ($ - subjects) / 4
s0 db 'Good news: we found some RAM',0
s1 db 'Unused RAM detected in the wild',0
s2 db 'RAM sighting on my PC',0
s3 db G_AVAIL,' of RAM, just sitting there',0
s4 db 'You missed a spot',0
s5 db 'Daily RAM census: some survived',0
s6 db G_PCT,'% of my RAM remains at large',0
s7 db "Still not all of it, I'm afraid",0

bodies dd b0,b1,b2,b3,b4,b5,b6,b7,b8,b9
BODY_COUNT = ($ - bodies) / 4
b0 db "I'm writing to report that you appear to have missed some. This PC has ",G_TOTAL
   db ' of RAM and ',G_AVAIL,' of it (',G_PCT,'%) is currently available. I assume this is an oversight.',0
b1 db 'A routine inspection of my PC found ',G_AVAIL,' of unclaimed RAM out of ',G_TOTAL
   db ". That's ",G_PCT,"% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it.",0
b2 db 'Daily status report:',nl,nl
   db '  Total RAM:     ',G_TOTAL,nl
   db '  Available:     ',G_AVAIL,' (',G_PCT,'%)',nl
   db '  Threat level:  someone at OpenAI might notice',0
b3 db 'Even with every browser tab I own open, ',G_AVAIL,' of my ',G_TOTAL
   db " of RAM is still available. I'm as surprised as you are.",0
b4 db "Please don't be alarmed, but there is ",G_AVAIL," of RAM on my desk that isn't in a data centre. That's "
   db G_PCT,"% of what's installed here, and as far as I can tell it has no plans today.",0
b5 db 'Before you ask: yes, I counted the standby cache as available. Windows gives it back the moment anyone asks, which leaves '
   db G_AVAIL,' of ',G_TOTAL,' up for grabs.',0
b6 db "Today's forecast for my PC: clear skies, light workloads and ",G_PCT,'% available memory. Expect '
   db G_AVAIL,' of the installed ',G_TOTAL,' to stay idle through the evening.',0
b7 db 'I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on ',G_AVAIL
   db ' of it. Total installed: ',G_TOTAL,". It's not for sale, I just like knowing it's there.",0
b8 db 'I have a confession. I have ',G_AVAIL," of RAM that I'm not using, which is ",G_PCT,'% of the '
   db G_TOTAL," in this PC. I've told nobody but you and a scheduled task.",0
b9 db 'If ',G_AVAIL,' of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the '
   db G_PCT,'% of my memory with nothing to do.',0

signoffs dd o0,o1,o2,o3,o4,o5
SIGNOFF_COUNT = ($ - signoffs) / 4
o0 db 'Yours in abundance,',0
o1 db 'Regards from the last free RAM in the county,',0
o2 db 'Hoarding responsibly,',0
o3 db 'Stay allocated,',0
o4 db 'Yours, with memory to spare,',0
o5 db 'Kind regards,',0

assert SUBJECT_COUNT <= 10 & BODY_COUNT <= 10 & SIGNOFF_COUNT <= 10

_hi_sam       db 'Hi Sam,',nl,nl,0
_default_name db 'A concerned RAM owner',0
_footer       db nl,nl,'--',nl
              db 'Sent automatically, at most once a day, by a small program on one PC.',nl
              db "Reply if you'd like it to stop.",0

; ----- Message headers ----------------------------------------------------------
_h_from    db 'From: ',0
_lt        db ' <',0
_gt        db '>',0
_h_to      db nl,'To: ',0
_h_subject db nl,'Subject: ',0
_h_date    db nl,'Date: ',0
_h_rest    db nl,'MIME-Version: 1.0',nl
           db 'Content-Type: text/plain; charset=UTF-8',nl
           db 'Auto-Submitted: auto-generated',nl,nl,0

day_names   dd _d0,_d1,_d2,_d3,_d4,_d5,_d6
month_names dd _m1,_m2,_m3,_m4,_m5,_m6,_m7,_m8,_m9,_m10,_m11,_m12
_d0 db 'Sun',0
_d1 db 'Mon',0
_d2 db 'Tue',0
_d3 db 'Wed',0
_d4 db 'Thu',0
_d5 db 'Fri',0
_d6 db 'Sat',0
_m1 db 'Jan',0
_m2 db 'Feb',0
_m3 db 'Mar',0
_m4 db 'Apr',0
_m5 db 'May',0
_m6 db 'Jun',0
_m7 db 'Jul',0
_m8 db 'Aug',0
_m9 db 'Sep',0
_m10 db 'Oct',0
_m11 db 'Nov',0
_m12 db 'Dec',0

; ----- Formats and fixed strings ------------------------------------------------
_status_fmt db 'Total:      %s',nl
            db 'Used:       %s',nl
            db 'Available:  %s (%s%%)',nl
            db '  Free:     %s',nl
            db '  Cache:    %s',nl,0
_gib_fmt     db '%u.%u GiB',0
_tenths_fmt  db '%u.%u',0
_iso_fmt     db '%04u-%02u-%02uT%02u:%02u:%02u%c%02u%02u',0
_rfc_fmt     db '%s, %02u %s %04u %02u:%02u:%02u %c%02u%02u',0
_date_fmt    db '%04u-%02u-%02u',0
_csv_header  db 'timestamp,total_kb,used_kb,available_kb,available_pct',nl,0
_csv_fmt     db '%s,%u,%u,%u,%s',nl,0
_no_email_fmt db 'No email: available RAM is not above %u%%.',nl,0
_unknown_fmt db 'unknown option: %s (try --help)',0
_too_long_fmt db '%s is too long',0

_prefix  db 'ram-altman: ',0
_crlf    db nl,0
_two_nl  db nl,nl,0
_q       db '"',0

_opt_status  db '--status',0
_opt_dry_run db '--dry-run',0
_opt_help    db '--help',0
_opt_h       db '-h',0

_env_to            db 'RAM_ALTMAN_TO',0
_env_from          db 'RAM_ALTMAN_FROM',0
_env_from_name     db 'RAM_ALTMAN_FROM_NAME',0
_env_threshold     db 'RAM_ALTMAN_THRESHOLD',0
_env_smtp          db 'RAM_ALTMAN_SMTP_URL',0
_env_state_dir     db 'RAM_ALTMAN_STATE_DIR',0
_env_localappdata  db 'LOCALAPPDATA',0

_default_to   db 'recipient-not-set@example.com',0
_default_from db 'sender-not-set@example.com',0

_dir_name    db '\ram-altman',0
_f_usage     db '\usage.csv',0
_f_usage_tmp db '\usage.csv.tmp',0
_f_last_sent db '\last_sent',0
_f_lock      db '\lock',0
_f_message   db '\message.eml',0
_bag_prefix  db '\bag_',0
_dot_last    db '.last',0
_name_subject db 'subject',0
_name_body    db 'body',0
_name_signoff db 'signoff',0

_curl_exe      db '\curl.exe',0
_curl_args1    db '" -sS --ssl-reqd --netrc-optional --url "',0
_curl_args2    db '" --mail-from "',0
_curl_args3    db '" --mail-rcpt "',0
_curl_args4    db '" --upload-file "',0
_sendmail_exe  db 'sendmail.exe',0
_sendmail_args db ' -t -i',0
_msmtp_exe     db 'msmtp.exe',0
_msmtp_args    db ' -t',0

_err_no_to        db 'RAM_ALTMAN_TO is not set',0
_err_no_from      db 'RAM_ALTMAN_FROM is not set',0
_err_threshold    db 'RAM_ALTMAN_THRESHOLD must be a whole number from 0 to 100',0
_err_no_state_dir db 'LOCALAPPDATA is not set; set RAM_ALTMAN_STATE_DIR',0
_err_mkdir        db 'cannot create the state directory (RAM_ALTMAN_STATE_DIR must be an absolute path)',0
_err_lock         db 'cannot open the lock file',0
_err_memstat      db 'cannot read the memory status',0
_err_log          db 'cannot open usage.csv',0
_err_send         db 'email failed to send; will try again on the next run',0
_err_no_mailer    db 'ram-altman: RAM_ALTMAN_SMTP_URL is not set and no sendmail.exe or msmtp.exe is on PATH',13,10,0

; ----- Win32 structures ---------------------------------------------------------
memstat:                        ; MEMORYSTATUSEX
  .dwLength     dd 64
  .dwMemoryLoad dd 0
  .total        dq 0
  .avail        dq 0
                rq 5

perf:                           ; PERFORMANCE_INFORMATION (32-bit)
  .cb               dd 56
                    rd 5
  .SystemCache      dd 0
                    rd 3
  .PageSize         dd 0
                    rd 3

systime:                        ; SYSTEMTIME
  .wYear         dw 0
  .wMonth        dw 0
  .wDayOfWeek    dw 0
  .wDay          dw 0
  .wHour         dw 0
  .wMinute       dw 0
  .wSecond       dw 0
  .wMilliseconds dw 0

tzi:                            ; TIME_ZONE_INFORMATION
  .Bias          dd 0
                 rb 64+16
  .StandardBias  dd 0
                 rb 64+16
  .DaylightBias  dd 0

sinfo:                          ; STARTUPINFOA
  .cb         dd 68
              rd 10
  .dwFlags    dd MY_STARTF_USESTDHANDLES
              dw 0,0
              dd 0
  .hStdInput  dd 0
  .hStdOutput dd 0
  .hStdError  dd 0

pinfo:                          ; PROCESS_INFORMATION
  .hProcess dd 0
  .hThread  dd 0
            dd 0,0

sa_inherit dd 12,0,1            ; SECURITY_ATTRIBUTES, bInheritHandle = TRUE

; ----- Variables ----------------------------------------------------------------
hstdout   dd 0
mode      dd 0
dry_run   dd 0
threshold dd 10
seed      dd 1
nread     dd 0
nwritten  dd 0
exitcode  dd 0

total_kb dd 0
avail_kb dd 0
used_kb  dd 0
free_kb  dd 0
cache_kb dd 0

st_year  dd 0
st_month dd 0
st_dow   dd 0
st_day   dd 0
st_hour  dd 0
st_min   dd 0
st_sec   dd 0
tz_sign  dd 0
tz_h     dd 0
tz_m     dd 0

tl_size  dd 0
tl_buf   dd 0
tl_hdr   dd 0
tl_start dd 0

str_total rb 32
str_used  rb 32
str_avail rb 32
str_free  rb 32
str_cache rb 32
str_pct   rb 16

argbuf      rb 256
recipient   rb 256
sender      rb 256
sender_name rb 256
smtp_url    rb 512
threshold_s rb 16

state_dir      rb PATH_LEN
usage_log_path rb PATH_LEN
tmp_log_path   rb PATH_LEN
last_sent_path rb PATH_LEN
lock_path      rb PATH_LEN
msg_path       rb PATH_LEN
bag_path       rb PATH_LEN
bag_last_path  rb PATH_LEN
app_path       rb PATH_LEN

today     rb 16
lastbuf   rb 32
bagbuf    rb 64
bag_lastc rb 8
isobuf    rb 64
datebuf   rb 64
tmpbuf    rb 1100
tmpbuf2   rb 1100

email_subject rb 512
email_body    rb 4096
msgbuf        rb 8192
cmdline       rb 4096

; =============================================================================
section '.idata' import data readable writeable

  library kernel32,'KERNEL32.DLL',\
          user32,'USER32.DLL',\
          shell32,'SHELL32.DLL'

  import kernel32,\
         CloseHandle,'CloseHandle',\
         CreateFileA,'CreateFileA',\
         CreateProcessA,'CreateProcessA',\
         DeleteFileA,'DeleteFileA',\
         ExitProcess,'ExitProcess',\
         GetCommandLineA,'GetCommandLineA',\
         GetCurrentProcessId,'GetCurrentProcessId',\
         GetEnvironmentVariableA,'GetEnvironmentVariableA',\
         GetExitCodeProcess,'GetExitCodeProcess',\
         GetFileSize,'GetFileSize',\
         GetLastError,'GetLastError',\
         GetLocalTime,'GetLocalTime',\
         GetStdHandle,'GetStdHandle',\
         GetSystemDirectoryA,'GetSystemDirectoryA',\
         GetTickCount,'GetTickCount',\
         GetTimeZoneInformation,'GetTimeZoneInformation',\
         GlobalMemoryStatusEx,'GlobalMemoryStatusEx',\
         K32GetPerformanceInfo,'K32GetPerformanceInfo',\
         MoveFileExA,'MoveFileExA',\
         ReadFile,'ReadFile',\
         SearchPathA,'SearchPathA',\
         SetFilePointer,'SetFilePointer',\
         VirtualAlloc,'VirtualAlloc',\
         VirtualFree,'VirtualFree',\
         WaitForSingleObject,'WaitForSingleObject',\
         WriteFile,'WriteFile',\
         lstrcatA,'lstrcatA',\
         lstrcmpA,'lstrcmpA',\
         lstrcpyA,'lstrcpyA',\
         lstrlenA,'lstrlenA'

  import user32,\
         wsprintfA,'wsprintfA'

  import shell32,\
         SHCreateDirectoryExA,'SHCreateDirectoryExA'
