/* RTFParser.j

 Parse a RTF string into a CPAttributedString

 Copyright (C) 2014 Daniel Boehringer
 Modifications for robust parsing and state management.

 This library is free software; you can redistribute it and/or

 modify it under the terms of the GNU Lesser General Public

 License as published by the Free Software Foundation; either

 version 2.1 of the License, or (at your option) any later version.

 This library is distributed in the hope that it will be useful,

 but WITHOUT ANY WARRANTY; without even the implied warranty of

 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU

 Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public

 License along with this library; if not, write to the Free Software

 Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

@import <Foundation/CPAttributedString.j>
@import <Foundation/CPGeometry.j>
@import "CPFontManager.j"
@import "CPParagraphStyle.j"

@global CPLeftTextAlignment
@global CPRightTextAlignment
@global CPCenterTextAlignment
@global CPJustifiedTextAlignment
@global CPNaturalTextAlignment

@global CPFontAttributeName
@global CPForegroundColorAttributeName
@global CPBackgroundColorAttributeName
@global CPUnderlineStyleAttributeName
@global CPStrikethroughStyleAttributeName

var hexTable =[];

// Hold the attributes of the current run
@implementation _RTFAttribute : CPObject
{
    CPRange _range;
    CPParagraphStyle paragraph;
    CPColor fgColour;
    CPColor bgColour;
    CPColor ulColour;
    CPString fontName;
    unsigned fontSize;
    BOOL bold;
    BOOL italic;
    BOOL underline;
    BOOL strikethrough;
    BOOL script;
    BOOL _tabChanged;
}

(id)init
{
    if (self =[super init])
    {
        [self resetFont];
        [self resetParagraphStyle];
        _range = CPMakeRange(0, 0);
        _tabChanged = NO;
    }

    return self;
}

- (id)copy
{
    var mynew = [_RTFAttribute new];

    mynew.paragraph = [paragraph copy];
    mynew.fontName = fontName;
    mynew.fontSize = fontSize;
    mynew.bold = bold;
    mynew.italic = italic;
    mynew.underline = underline;
    mynew.strikethrough = strikethrough;
    mynew.script = script;
    mynew.fgColour = fgColour;
    mynew.bgColour = bgColour;
    mynew.ulColour = ulColour;

    // Copy internal tab tracking
    mynew._tabChanged = _tabChanged;

    return mynew;
}

- (CPFont)currentFont
{
    var font =[CPFont _fontWithName:fontName size:fontSize bold:bold italic:italic];

    if (font)
        return font;

    //Before giving up and using a default font, we try if this is
    //not the case of a font with a composite name, such as
    //'Helvetica-Light'. In that case, even if we don't have
    //exactly an 'Helvetica-Light' font family, we might have an
    //'Helvetica' one.
    var range = [fontName rangeOfString:@"-"];

    if (range.location != CPNotFound)
    {
        var fontFamily = [fontName substringToIndex: range.location];
        font =[CPFont fontWithName:fontFamily size:fontSize];

    }

    /* Last resort, default font. :-( */
    if (font == nil)
        font = [CPFont systemFontOfSize:fontSize];

    return font;
}

- (CPNumber)script
{
    return [CPNumber numberWithInt:script];
}

- (CPNumber)underline
{
    if (underline != 0)
        return [CPNumber numberWithInt:underline];
    else
        return nil;
}

- (CPNumber)strikethrough
{
    if (strikethrough != 0)
        return [CPNumber numberWithInt:strikethrough];
    else
        return nil;
}

- (void)resetParagraphStyle
{
    paragraph = [[CPParagraphStyle defaultParagraphStyle] copy];
}

- (void)resetFont
{
    var font = [CPFont systemFontOfSize:12];

    fontName = [font familyName];
    fontSize = 12.0;
    italic = NO;
    bold = NO;
    underline = 0;
    strikethrough = 0;
    script = 0;
}

- (void)addTab:(float)location type:(CPTextTabType)type
{
    var tab = [[CPTextTab alloc] initWithType:type location:location];

    if (!_tabChanged)
    {
        [paragraph setTabStops:[tab]];
        _tabChanged = YES;
    }
    else
    {
        [paragraph addTabStop: tab];
    }
}

- (CPDictionary)dictionary
{
    var ret = @{};[ret setObject:[self currentFont] forKey:CPFontAttributeName];[ret setObject:paragraph forKey:CPParagraphStyleAttributeName];

    if (fgColour)
        [ret setObject:fgColour forKey:CPForegroundColorAttributeName];

    if (bgColour)
        [ret setObject:bgColour forKey:CPBackgroundColorAttributeName];

    if (underline)
        [ret setObject:[self underline] forKey:CPUnderlineStyleAttributeName];

    if (strikethrough)
        [ret setObject:[self strikethrough] forKey:CPStrikethroughStyleAttributeName];

    return ret;
}
@end

// based on https://github.com/lazygyu/RTF-parser

var kRTFParserType_char = 0,
    kRTFParserType_dest = 1,
    kRTFParserType_prop = 2,
    kRTFParserType_spec = 3;

// Keyword descriptions
var kRgsymRtf = {
                                             //  keyword     dflt    fPassDflt    kwd                        idx
        "b"                                  : [ "b",        1,        false,     kRTFParserType_prop,    "propBold"],
        "ul"                                 : [ "ul",       1,        false,     kRTFParserType_prop,    "propUnderline"],
        "i"                                  : [ "i",        1,        false,     kRTFParserType_prop,    "propItalic"],
        "li"                                 : [ "li",       0,        false,     kRTFParserType_prop,    "propPgnFormat"],
        "pgnucltr"                           : [ "pgnucltr", "pgULtr", true,      kRTFParserType_prop,    "propPgnFormat"],
        "pgnlcltr"                           : [ "pgnlcltr", "pgLLtr", true,      kRTFParserType_prop,    "propPgnFormat"],
        "qc"                                 : [ "qc",       "justC",  true,      kRTFParserType_prop,    "propJust"],
        "ql"                                 : [ "ql",       "justL",  true,      kRTFParserType_prop,    "propJust"],
        "qr"                                 : [ "qr",       "justR",  true,      kRTFParserType_prop,    "propJust"],
        "qj"                                 : [ "qj",       "justF",  true,      kRTFParserType_prop,    "propJust"],
        "paperw"                             : [ "paperw",   12240,    false,     kRTFParserType_prop,    "propXaPage"],
        "paperh"                             : [ "paperh",   15480,    false,     kRTFParserType_prop,    "propYaPage"],
        "margl"                              : [ "margl",    1800,     false,     kRTFParserType_prop,    "propXaLeft"],
        "margr"                              : [ "margr",    1800,     false,     kRTFParserType_prop,    "propXaRight"],
        "margt"                              : [ "margt",    1440,     false,     kRTFParserType_prop,    "propYaTop"],
        "margb"                              : [ "margb",    1440,     false,     kRTFParserType_prop,    "propYaBottom"],
        "pgnstart"                           : [ "pgnstart", 1,        true,      kRTFParserType_prop,    "propPgnStart"],
        "facingp"                            : [ "facingp",  1,        true,      kRTFParserType_prop,    "propFacingp"],
        "landscape"                          : [ "landscape",1,        true,      kRTFParserType_prop,    "propLandscape"],
        "par"                                : [ "par",      0,        false,     kRTFParserType_char,    "\n"],
        "pard"                               : [ "pard",     0,        false,     kRTFParserType_prop,    "propDefaultPara"],
        "\0x0a"                              : [ "\0x0a",    0,        false,     kRTFParserType_char,    "\n"],
        "\0x0d"                              : [ "\0x0d",    0,        false,     kRTFParserType_char,    ""],
        "tab"                                : [ "tab",      0,        false,     kRTFParserType_char,    "\t"],
        "ldblquote"                          : [ "ldblquote",0,        false,     kRTFParserType_char,    '"'],
        "rdblquote"                          : [ "rdblquote",0,        false,     kRTFParserType_char,    '"'],
        "bin"                                : [ "bin",      0,        false,     kRTFParserType_spec,    "ipfnBin"],
        "*"                                  : [ "*",        0,        false,     kRTFParserType_spec,    "ipfnDestSkip"],
        "'"                                  : [ "'",        0,        false,     kRTFParserType_spec,    "ipfnHex"],
        "author"                             : [ "author",   0,        false,     kRTFParserType_dest,    "destSkip"],
        "buptim"                             : [ "buptim",   0,        false,     kRTFParserType_dest,    "destSkip"],
        "colortbl"                           : [ "colortbl", 0,        false,     kRTFParserType_dest,    "destSkip"],
        "comment"                            : [ "comment",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "creatim"                            : [ "creatim",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "doccomm"                            : [ "doccomm",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "fonttbl"                            : [ "fonttbl",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "footer"                             : [ "footer",   0,        false,     kRTFParserType_dest,    "destSkip"],
        "footerf"                            : [ "footerf",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "footerl"                            : [ "footerl",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "footerr"                            : [ "footerr",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "footnote"                           : [ "footnote", 0,        false,     kRTFParserType_dest,    "destSkip"],
        "ftncn"                              : [ "ftncn",    0,        false,     kRTFParserType_dest,    "destSkip"],
        "ftnsep"                             : [ "ftnsep",   0,        false,     kRTFParserType_dest,    "destSkip"],
        "ftnsepc"                            : [ "ftnsepc",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "fprq"                               : [ "fprq",     0,        false,     kRTFParserType_dest,    "destSkip"],
//      "fcharset"                           : [ "fcharset", 0,        false,     kRTFParserType_dest,    "destSkip"],
        "rquote"                             : [ "rquote",   0,        false,     kRTFParserType_char,    "'"],
//      "s"                                  : [ "s",        0,        false,     kRTFParserType_dest,    "destSkip"],
        "header"                             : [ "header",   0,        false,     kRTFParserType_dest,    "destSkip"],
        "headerf"                            : [ "headerf",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "headerl"                            : [ "headerl",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "headerr"                            : [ "headerr",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "info"                               : [ "info",     0,        false,     kRTFParserType_dest,    "destSkip"],
        "keywords"                           : [ "keywords", 0,        false,     kRTFParserType_dest,    "destSkip"],
        "operator"                           : [ "operator", 0,        false,     kRTFParserType_dest,    "destSkip"],
        "pict"                               : [ "pict",     0,        false,     kRTFParserType_dest,    "destSkip"],
        "printim"                            : [ "printim",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "private1"                           : [ "private1", 0,        false,     kRTFParserType_dest,    "destSkip"],
        "revtim"                             : [ "revtim",   0,        false,     kRTFParserType_dest,    "destSkip"],
        "rxe"                                : [ "rxe",      0,        false,     kRTFParserType_dest,    "destSkip"],
        "stylesheet"                         : [ "stylesheet",0,       false,     kRTFParserType_dest,    "destSkip"],
        "subject"                            : [ "subject",  0,        false,     kRTFParserType_dest,    "destSkip"],
        "tc"                                 : [ "tc",       0,        false,     kRTFParserType_dest,    "destSkip"],
        "title"                              : [ "title",    0,        false,     kRTFParserType_dest,    "destSkip"],
        "txe"                                : [ "txe",      0,        false,     kRTFParserType_dest,    "destSkip"],
        "xe"                                 : [ "xe",       0,        false,     kRTFParserType_dest,    "destSkip"],
        "["                                  : [ "[",        0,        false,     kRTFParserType_char,    '['],
        " "                                  : [ " ",        0,        false,     kRTFParserType_char,    ' '],
        "]"                                  : [ "]",        0,        false,     kRTFParserType_char,    ']'],
        "{"                                  : [ "{",        0,        false,     kRTFParserType_char,    '{'],
        "}"                                  : [ "}",        0,        false,     kRTFParserType_char,    '}'],
        "\\"                                 : [ "\\",       0,        false,     kRTFParserType_char,    '\\']
    };

@implementation _CPRTFParser : CPObject
{
    CPString _codePage;
    CGSize _paper;
    CPString _rtf;
    unsigned _curState;
    CPArray _states;
    unsigned _currentParseIndex;
    BOOL _hexreturn;
    _RTFAttribute _currentRun;
    CPAttributedString _result;
    CPArray _colorArray;
    CPArray _fontArray;
    CPString _freename;

    // Table parsing properties
    BOOL                _parsingFontTable;
    BOOL                _parsingColorTable;
    int                 _currentColorR;
    int                 _currentColorG;
    int                 _currentColorB;

}

- (id)init
{
    if (self = [super init])
    {
        _paper = CPMakeSize(0, 0);
        _rtf = "";
        _curState = 0; // 0 = normal, 1+ = skip
        _states = [];
        _currentParseIndex = 0;
        _hexreturn = NO;
        _result = [CPAttributedString new];
        _colorArray = [];
        _fontArray = [[[CPFont systemFontOfSize:12] familyName]];
        _freename = "";

        _parsingFontTable   = NO;
        _parsingColorTable  = NO;
        _currentColorR      = 0;
        _currentColorG      = 0;
        _currentColorB      = 0;

    }

    return self;
}

- (CPString)_checkChar:(CPArray)sym parameter:(CPString)ch
{
    switch (_curState)
    {
        case 0:
            if (sym && sym[4])
                return sym[4];
            break;
        default:
            // Skip unless it's a structural character we still need
            if (sym && sym[4])
                return '';
            break;

    }

    return '';
}

- (BOOL)pushState
{
    [self _flushCurrentRun];

    _states.push({
        run: [_currentRun copy],
        skipCount: _curState,
        parsingFontTable: _parsingFontTable,
        parsingColorTable: _parsingColorTable
    });

    _currentRun._range = CPMakeRange([_result length], 0);

    return YES;
}

- (BOOL)popState
{
    if (_states.length > 0)
    {
        [self _flushCurrentRun];

        var popped = _states.pop();

        _currentRun = popped.run;
        _curState = popped.skipCount;
        _parsingFontTable = popped.parsingFontTable;
        _parsingColorTable = popped.parsingColorTable;

        _currentRun._range = CPMakeRange([_result length], 0);

        return YES;

    }

    return NO;
}

- (CPString)_parseSpec:(CPArray)sym parameter:(CPString)v
{
    var ch = '';

    switch (sym[4])
    {
        case "ipfnDestSkip":
            _curState++;
            return '';

        case "ipfnHex":
            ch = _rtf.charAt(++_currentParseIndex);

            var hex = '';

            while (new RegExp("[a-fA-F0-9\\']").test(ch))
            {
                if (ch == "'")
                {
                    _currentParseIndex++;
                    continue;
                }

                hex += (ch + '');
                ch = _rtf.charAt(++_currentParseIndex);
            }

            _hexreturn = YES;
            _currentParseIndex--;

            if (_curState !== 0)
                return '';
            else
                return hex;
            break;

        case "codePage":
            ch = _rtf.charAt(++_currentParseIndex);

            var code = '';

            while (new RegExp("[0-9]").test(ch))
            {
                code += (ch + '');
                ch = _rtf.charAt(++_currentParseIndex);
            }

            _codePage = code;
            _currentParseIndex--;
            break;

    }

    return '';
}

(void)_flushCurrentRun
{
    var newOffset = 0;

    if (_currentRun)
    {
        if ([_result length] == _currentRun._range.location)
            return;

        _currentRun._range.length = [_result length] - _currentRun._range.location;
        newOffset = CPMaxRange(_currentRun._range);

        var dict = [_currentRun dictionary];

        [_result setAttributes:dict range:_currentRun._range];  // flush previous run

    }
    else
    {
        _currentRun =[_RTFAttribute new];
    }

    _currentRun._range = CPMakeRange(newOffset, 0); // open a new one
}

- (CPString)_applyPropChange:(CPArray)sym parameter:(int)param
{
    switch (sym[0])
    {
        case "pard":[self _flushCurrentRun];
            [_currentRun resetParagraphStyle];
            break;

            code
            Code
            download
            content_copy
            expand_less
        case "b": // bold
            [self _flushCurrentRun];
            _currentRun.bold = (param !== 0);
            break;

        case "i": // italic
            [self _flushCurrentRun];
            _currentRun.italic = (param !== 0);
            break;

        case "ul": // underline
            [self _flushCurrentRun];
            _currentRun.underline = (param !== 0) ? 1 : 0;
            break;

        case "qc":  // paragraph center
            [self _flushCurrentRun];
            [_currentRun.paragraph setAlignment:CPCenterTextAlignment];
            break;

        case "ql":  // paragraph left
            [self _flushCurrentRun];
            [_currentRun.paragraph setAlignment:CPLeftTextAlignment];
            break;

        case "qr":  // paragraph right
            [self _flushCurrentRun];[_currentRun.paragraph setAlignment:CPRightTextAlignment];
            break;

        case "qj":  // paragraph justified
            [self _flushCurrentRun];[_currentRun.paragraph setAlignment:CPJustifiedTextAlignment];
            break;

        case "sa": // space after
            [self _flushCurrentRun];
            if ([_currentRun.paragraph respondsToSelector:@selector(setParagraphSpacing:)])[_currentRun.paragraph setParagraphSpacing:param / 20.0];
            break;

        case "sb": // space before
            [self _flushCurrentRun];
            if ([_currentRun.paragraph respondsToSelector:@selector(setParagraphSpacingBefore:)])[_currentRun.paragraph setParagraphSpacingBefore:param / 20.0];
            break;

        case "sl": // line spacing[self _flushCurrentRun];
            if ([_currentRun.paragraph respondsToSelector:@selector(setLineSpacing:)])
                [_currentRun.paragraph setLineSpacing:param / 20.0];
            break;

        case "cf":  // change foreground color
            [self _flushCurrentRun];
            if (_colorArray && param >= 0 && param < _colorArray.length)
                _currentRun.fgColour = _colorArray[param];
            break;

        case "f":  // change font
            [self _flushCurrentRun];
            if (_fontArray && param >= 0 && param < _fontArray.length)
                _currentRun.fontName = _fontArray[param];
            break;

        case "fs":  // change font size
            [self _flushCurrentRun];
            _currentRun.fontSize = param / 2.0;
            break;

        case "paperw":
            _paper.width = param;
            break;

        case "paperh":
            _paper.height = param;
            break;

    }

    return '';
}

- (CPString)_changeDest:(CPArray)sym
{
    switch (sym[0])
    {
        case "colortbl":
            _parsingColorTable = YES;
            _colorArray = [[CPColor blackColor]]; // 0 index is typically auto/black
            _currentColorR = 0;
            _currentColorG = 0;
            _currentColorB = 0;
            break;

            code
            Code
            download
            content_copy
            expand_less
        case "fonttbl":
            _parsingFontTable = YES;
            _freename = "";
            break;

    }

    if (sym[4] == "destSkip")
    {
        _curState++;
    }

    return '';
}

- (CPString)_translateKeyword:(CPString)keyword parameter:(CPString)param fParameter:(BOOL)fParam
{
    if (kRgsymRtf[keyword] !== undefined)
    {
        var sym = kRgsymRtf[keyword];

        switch (sym[3])
        {
            case kRTFParserType_prop:
                if (sym[2]  || !fParam)
                    param = sym[1];

                return [self _applyPropChange:sym parameter:param];

            case kRTFParserType_char:
                if((param + '') !== 'NaN' && (param + '') !== 'null' && (param + '').length)
                    _currentParseIndex -= (param + '').length;

                return [self _checkChar:sym parameter:param];

            case kRTFParserType_dest:
                return [self _changeDest:sym];

            case kRTFParserType_spec:
                return [self _parseSpec:sym parameter:param];

            default:
                return '';
        }

    }
    else
    {
        switch (keyword)
        {
            case "red":
                _currentColorR = parseInt(param);
                break;

                code
                Code
                download
                content_copy
                expand_less
            case "green":
                _currentColorG = parseInt(param);
                break;

            case "blue":
                _currentColorB = parseInt(param);
                break;

            case "tx":  // tabstop
                var location = parseInt(param) / 20.0;
                if (_currentRun)[_currentRun addTab:location type:CPLeftTabStopType];
                break;

            default:
                // CPLogConsole("skip : " + keyword + " param: " + param);
                break;

        }

        if (_states.length > 0)
            _curState = 1;

        return '';

    }
}

- (CPString)_parseKeyword:(CPString)rtf length:(unsigned)len
{
    var ch = '',
    fParam = false,
    fNeg = false,
    keyword = '',
    param = '';

    _rtf = rtf;

    if (++_currentParseIndex >= len)
        return len;

    ch = rtf.charAt(_currentParseIndex);

    if (!/[a-zA-Z]/.test(ch))
        return[self _translateKeyword:ch parameter:nil fParameter:fParam];

    while (new RegExp("[a-zA-Z]").test(ch))
    {
        keyword += ch;
        ch = rtf.charAt(++_currentParseIndex);
    }

    if (ch == '-')
    {
        fNeg = true;
        ch = rtf.charAt(++_currentParseIndex);
    }

    fParam = true;

    while (new RegExp("[0-9]").test(ch))
    {
        param += (ch + '');
        ch = rtf.charAt(++_currentParseIndex);
    }

    _currentParseIndex--;
    param = parseInt(param);

    if (fNeg)
        param *= -1;

    return [self _translateKeyword:keyword parameter:param fParameter:fParam];
}

- (void)_appendPlainString:(CPString)aString
{
    [_result replaceCharactersInRange:CPMakeRange([_result length], 0) withString:aString];
}

- (CPAttributedString)parseRTF:(CPString)rtf
{
    rtf = rtf.replace(/\\n/g, "\par\n");

    if (rtf.length == 0)
        return '';

    _currentParseIndex = -1;

    var len = rtf.length,
    tmp = '',
    ch = '',
    hex = '',
    lastchar = 0;

    while (_currentParseIndex < len)
    {
        tmp = rtf.charAt(++_currentParseIndex);

        if (tmp !== "\\" && hex.length > 0)
        {
            [self _appendPlainString: String.fromCharCode(parseInt((hex), 16))];
            hex = '';
        }

        switch (tmp)
        {
            case " ":
                if (lastchar == 1)
                {
                    // Space acts as delimiter after a keyword, consume it
                    lastchar = 0;
                }
                else
                {
                    if (_curState === 0)
                    {
                        [self _appendPlainString:tmp];
                    }
                    else if (_parsingFontTable || _parsingColorTable)
                    {
                        _freename += tmp;
                    }
                }
                break;

            case "{":
                [self pushState];
                break;

            case "}":
                [self popState];
                break;

            case ";":
                if (_parsingColorTable)
                {
                    _colorArray.push([CPColor colorWithRed:_currentColorR / 255.0 green:_currentColorG / 255.0 blue:_currentColorB / 255.0 alpha:1.0]);
                    _currentColorR = 0;
                    _currentColorG = 0;
                    _currentColorB = 0;
                }
                else if (_parsingFontTable)
                {
                    if (_freename.length > 0)
                    {
                        _fontArray.push(_freename.replace(/['"]/g, "").trim());
                                                            _freename = "";
                    }
                }
                else
                {
                    lastchar = 0;
                    if (_curState === 0)
                        [self _appendPlainString:tmp];
                }
                break;

            case "\\":
                ch =[self _parseKeyword:rtf length:len];

                if (!_hexreturn && ch.length == 0)
                    lastchar = 1;
                else
                    lastchar = 0;

                if (_hexreturn)
                {
                    if (ch.length > 0)
                    {
                        if (parseInt(ch, 16) & 0x80)
                        {
                            hex += ch.toUpperCase();
                        }
                        else
                        {
                            [self _appendPlainString: String.fromCharCode(parseInt((hex + ch), 16))];
                            hex = '';
                        }

                        if (hex.length == 4)
                        {
                            var temp = parseInt(hex, 16);

                            if (hexTable && hexTable[hex.toUpperCase()] !== undefined)
                                temp = parseInt(hexTable[hex.toUpperCase()], 16);

                            [self _appendPlainString: String.fromCharCode(temp)];
                            hex = '';
                        }
                    }

                    _hexreturn = NO;
                }
                else if (ch !== undefined && _curState === 0)
                {
                    [self _appendPlainString:ch];
                }

                break;

            case 0x0d:
            case 0x0a:
            case '\n':
            case '\r':
                break;

            default:
                lastchar = 0;

                if (_curState === 0)
                {
                    [self _appendPlainString:tmp];
                }
                else if (_parsingFontTable || _parsingColorTable)
                {
                    _freename += tmp;
                }

                break;
        }

    }

    [self _flushCurrentRun];

    return _result;
}

@end
