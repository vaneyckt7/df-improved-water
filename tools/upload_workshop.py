"""Upload the built mod folder to the Steam Workshop through the running Steam client.

    python tools/upload_workshop.py <libsteam_api library> [mod folder] [private|friends|public]

Reads title, tags, key-value tags, change note and the item number from the folder's info.txt and
the page text from steam/workshop_description.txt. Without [STEAM_FILE_ID:...] in info.txt a new
item is created and its number is written to steam/info.txt and the folder's info.txt before the
files go up. Visibility is set in the same update as the files (default: private). Steam must be
running and logged in to an account that owns Dwarf Fortress. Any game's copy of the library
(libsteam_api.dylib / .so / steam_api64.dll) will do.
"""
import ctypes
import os
import re
import sys
import time

APP = 975370
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VISIBILITY = {'public': 0, 'friends': 1, 'private': 2}


class CallbackMsg(ctypes.Structure):
    _pack_ = 4 if sys.platform != 'win32' else 8
    _layout_ = 'ms'
    _fields_ = [('user', ctypes.c_int32), ('callback', ctypes.c_int32),
                ('param', ctypes.c_void_p), ('size', ctypes.c_int32)]


class CallCompleted(ctypes.Structure):
    _pack_ = 4 if sys.platform != 'win32' else 8
    _layout_ = 'ms'
    _fields_ = [('call', ctypes.c_uint64), ('callback', ctypes.c_int32), ('size', ctypes.c_uint32)]


class CreateItemResult(ctypes.Structure):
    _pack_ = 4 if sys.platform != 'win32' else 8
    _layout_ = 'ms'
    _fields_ = [('result', ctypes.c_int32), ('file_id', ctypes.c_uint64), ('needs_agreement', ctypes.c_bool)]


class SubmitResult(ctypes.Structure):
    _pack_ = 4 if sys.platform != 'win32' else 8
    _layout_ = 'ms'
    _fields_ = [('result', ctypes.c_int32), ('needs_agreement', ctypes.c_bool), ('file_id', ctypes.c_uint64)]


class StringArray(ctypes.Structure):
    _fields_ = [('strings', ctypes.POINTER(ctypes.c_char_p)), ('count', ctypes.c_int32)]


def wait_for(api, pipe, call, result_type, expected_callback, timeout=600):
    """Pump Steam's callbacks until the given call has finished; return its result struct."""
    end = time.time() + timeout
    msg = CallbackMsg()
    while time.time() < end:
        api.SteamAPI_ManualDispatch_RunFrame(pipe)
        while api.SteamAPI_ManualDispatch_GetNextCallback(pipe, ctypes.byref(msg)):
            try:
                if msg.callback == 703:
                    done = ctypes.cast(msg.param, ctypes.POINTER(CallCompleted)).contents
                    if done.call == call:
                        if done.callback != expected_callback:
                            sys.exit('unexpected answer %d from Steam' % done.callback)
                        result = result_type()
                        failed = ctypes.c_bool(False)
                        ok = api.SteamAPI_ManualDispatch_GetAPICallResult(
                            pipe, ctypes.c_uint64(call), ctypes.byref(result),
                            ctypes.sizeof(result), expected_callback, ctypes.byref(failed))
                        if not ok or failed.value:
                            sys.exit('Steam could not complete the call')
                        return result
            finally:
                api.SteamAPI_ManualDispatch_FreeLastCallback(pipe)
        time.sleep(0.1)
    sys.exit('timed out waiting for Steam')


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    library = sys.argv[1]
    folder = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'dist', 'improved_water'))
    visibility = VISIBILITY[sys.argv[3] if len(sys.argv) > 3 else 'private']
    info_path = os.path.join(folder, 'info.txt')
    info = open(info_path, encoding='utf-8').read()

    def field(name):
        return re.findall(r'\[%s:([^\]]*)\]' % name, info)

    title = field('STEAM_TITLE')[0]
    tags = field('STEAM_TAG')
    pairs = [value.split(':', 1) for value in field('STEAM_KEY_VALUE_TAG')]
    note = (field('STEAM_CHANGELOG') or [''])[0]
    file_id = int(field('STEAM_FILE_ID')[0]) if field('STEAM_FILE_ID') else 0
    description = open(os.path.join(ROOT, 'steam', 'workshop_description.txt'), encoding='utf-8').read()
    preview = os.path.join(folder, 'preview.png')
    if not os.path.isfile(preview) or not os.path.isdir(os.path.join(folder, 'scripts_modinstalled')):
        sys.exit('%s is not a built mod folder' % folder)

    os.environ['SteamAppId'] = os.environ['SteamGameId'] = str(APP)
    api = ctypes.CDLL(library)
    api.SteamAPI_SteamUGC_v021.restype = ctypes.c_void_p
    api.SteamAPI_ISteamUGC_CreateItem.restype = ctypes.c_uint64
    api.SteamAPI_ISteamUGC_CreateItem.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int32]
    api.SteamAPI_ISteamUGC_StartItemUpdate.restype = ctypes.c_uint64
    api.SteamAPI_ISteamUGC_StartItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64]
    for name in ('SetItemTitle', 'SetItemDescription', 'SetItemContent', 'SetItemPreview'):
        function = getattr(api, 'SteamAPI_ISteamUGC_' + name)
        function.restype = ctypes.c_bool
        function.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
    api.SteamAPI_ISteamUGC_SetItemVisibility.restype = ctypes.c_bool
    api.SteamAPI_ISteamUGC_SetItemVisibility.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_int32]
    api.SteamAPI_ISteamUGC_SetItemTags.restype = ctypes.c_bool
    api.SteamAPI_ISteamUGC_SetItemTags.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(StringArray), ctypes.c_bool]
    api.SteamAPI_ISteamUGC_AddItemKeyValueTag.restype = ctypes.c_bool
    api.SteamAPI_ISteamUGC_AddItemKeyValueTag.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_char_p]
    api.SteamAPI_ISteamUGC_SubmitItemUpdate.restype = ctypes.c_uint64
    api.SteamAPI_ISteamUGC_SubmitItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
    api.SteamAPI_ManualDispatch_GetAPICallResult.restype = ctypes.c_bool
    api.SteamAPI_ManualDispatch_GetNextCallback.restype = ctypes.c_bool
    api.SteamAPI_InitFlat.restype = ctypes.c_int32

    error = ctypes.create_string_buffer(1024)
    if api.SteamAPI_InitFlat(error) != 0:
        sys.exit('Steam did not start the session: ' + error.value.decode(errors='replace'))
    try:
        api.SteamAPI_ManualDispatch_Init()
        pipe = api.SteamAPI_GetHSteamPipe()
        ugc = ctypes.c_void_p(api.SteamAPI_SteamUGC_v021())

        if not file_id:
            created = wait_for(api, pipe, api.SteamAPI_ISteamUGC_CreateItem(ugc, APP, 0), CreateItemResult, 3403)
            if created.result != 1:
                sys.exit('Steam refused to create the item, result %d' % created.result)
            file_id = created.file_id
            print('created item', file_id, '| Workshop agreement still to accept:', created.needs_agreement)
            line = '[STEAM_FILE_ID:%d]\n' % file_id
            for path in (info_path, os.path.join(ROOT, 'steam', 'info.txt')):
                with open(path, 'a', encoding='utf-8') as out:
                    out.write(line)

        update = api.SteamAPI_ISteamUGC_StartItemUpdate(ugc, APP, file_id)
        strings = (ctypes.c_char_p * len(tags))(*[tag.encode() for tag in tags])
        array = StringArray(strings, len(tags))
        steps = [
            ('visibility', api.SteamAPI_ISteamUGC_SetItemVisibility(ugc, update, visibility)),
            ('title', api.SteamAPI_ISteamUGC_SetItemTitle(ugc, update, title.encode())),
            ('description', api.SteamAPI_ISteamUGC_SetItemDescription(ugc, update, description.encode())),
            ('tags', api.SteamAPI_ISteamUGC_SetItemTags(ugc, update, ctypes.byref(array), False)),
            ('content', api.SteamAPI_ISteamUGC_SetItemContent(ugc, update, folder.encode())),
            ('preview', api.SteamAPI_ISteamUGC_SetItemPreview(ugc, update, preview.encode())),
        ]
        for key, value in pairs:
            steps.append(('key-value tag ' + key, api.SteamAPI_ISteamUGC_AddItemKeyValueTag(ugc, update, key.encode(), value.encode())))
        refused = [name for name, ok in steps if not ok]
        if refused:
            sys.exit('Steam refused: %s (item %d left as it was)' % (', '.join(refused), file_id))
        done = wait_for(api, pipe, api.SteamAPI_ISteamUGC_SubmitItemUpdate(ugc, update, note.encode()), SubmitResult, 3404)
        print('upload result', done.result, '(1 is success) | item', file_id, '| tags', ', '.join(tags),
              '| visibility', [k for k, v in VISIBILITY.items() if v == visibility][0],
              '| Workshop agreement still to accept:', done.needs_agreement)
        if done.result != 1:
            sys.exit(1)
    finally:
        api.SteamAPI_Shutdown()


if __name__ == '__main__':
    main()
