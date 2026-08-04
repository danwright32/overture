import Foundation

// #2087: the REAL signature HTML behind #2086, exported from the live Release app's cached
// `gmailSignatureHTML` (UserDefaults, com.danwright.overture) on 2026-08-04, 2,084 characters,
// byte for byte. Not written by hand, and not shaped to make the detector fire (L48): this is the
// value that was on the wire of every Overture pitch, and its three `border:1px solid` white rules
// are the outline box every dark-mode recipient saw.
//
// Kept in one place so both the detector's tests and any later reader measure the same real thing.
enum Signature2086Fixture {

    // As cached, and as sent. Three near-white border rules on nested wrapper divs, plus two
    // `border:0px` rules and three `border="0"` attributes on the social icons that a detector must
    // NOT mistake for them.
    static let asSent = #"""
<div dir="ltr"><div dir="ltr"><div dir="ltr"><div style="color:rgb(0,0,0);font-family:-webkit-standard;min-width:600px;width:600px;border:1px solid rgb(255,255,255)"><div style="min-width:600px;width:100%;border:1px solid #fff"><div style="min-width:600px;width:100%;border:1px solid #fff"><table cellspacing="0" cellpadding="0" border="0" width="310" style="color:rgb(213,218,222);font-family:-apple-system,sans-serif;font-size:14px;table-layout:fixed;word-break:break-word;max-width:310px"><tbody><tr><td style="color:rgb(85,85,85);font-size:13px;line-height:26px;padding-top:15px;font-family:Helvetica,Arial,sans-serif"><p style="margin:0.1px"><span style="font-weight:bold;color:rgb(5,140,144);font-size:17px">Dan Wright<span> </span></span><span style="color:rgb(102,102,102)">he/they</span></p></td></tr><tr><td style="color:rgb(85,85,85);font-size:13px;line-height:20px;font-family:Helvetica,Arial,sans-serif"><p style="margin:0.1px"></p></td></tr><tr><td style="color:rgb(85,85,85);font-size:13px;line-height:20px;font-family:Helvetica,Arial,sans-serif"><p style="margin:0.1px"><a href="https://www.danwrightphotography.com/" style="color:rgb(5,140,144);text-decoration:none" target="_blank">www.danwrightphotography.com</a></p></td></tr><tr><td style="color:rgb(85,85,85);font-size:13px;height:32px;padding-top:10px;font-family:Helvetica,Arial,sans-serif"><p style="margin:0.1px"><a href="https://www.facebook.com/DWphotoNY/" style="display:inline-block;padding-right:4px;vertical-align:middle" target="_blank"><img src="https://icon.signature.email/social/facebook-rounded-medium-FFFFFF-333333.png" width="32" height="32" border="0" alt="Facebook" style="border:0px;display:inline-block"></a><a href="https://www.instagram.com/DWphotoNY/" style="display:inline-block;padding-right:4px;vertical-align:middle" target="_blank"><img src="https://icon.signature.email/social/instagram-rounded-medium-FFFFFF-333333.png" width="32" height="32" border="0" alt="Instagram" style="border:0px;display:inline-block"></a></p></td></tr></tbody></table></div></div></div></div></div></div>
"""#

    // The same signature WITHOUT the three bordered wrapper divs, which is the shape the mail client
    // embeds from its own local copy. #2086 compared both messages' raw MIME in the Gmail Sent
    // mailbox and found the client's copy carried zero border rules; this is that difference and
    // nothing else, derived from the real value above rather than composed independently.
    static let asTheMailClientSendsIt = #"""
<div dir="ltr"><div dir="ltr"><div dir="ltr"><table cellspacing="0" cellpadding="0" border="0" width="310" style="color:rgb(213,218,222);font-family:-apple-system,sans-serif;font-size:14px;table-layout:fixed;word-break:break-word;max-width:310px"><tbody><tr><td style="color:rgb(85,85,85);font-size:13px;line-height:26px;padding-top:15px;font-family:Helvetica,Arial,sans-serif"><p style="margin:0.1px"><span style="font-weight:bold;color:rgb(5,140,144);font-size:17px">Dan Wright<span> </span></span><span style="color:rgb(102,102,102)">he/they</span></p></td></tr><tr><td style="color:rgb(85,85,85);font-size:13px;line-height:20px;font-family:Helvetica,Arial,sans-serif"><p style="margin:0.1px"></p></td></tr><tr><td style="color:rgb(85,85,85);font-size:13px;line-height:20px;font-family:Helvetica,Arial,sans-serif"><p style="margin:0.1px"><a href="https://www.danwrightphotography.com/" style="color:rgb(5,140,144);text-decoration:none" target="_blank">www.danwrightphotography.com</a></p></td></tr><tr><td style="color:rgb(85,85,85);font-size:13px;height:32px;padding-top:10px;font-family:Helvetica,Arial,sans-serif"><p style="margin:0.1px"><a href="https://www.facebook.com/DWphotoNY/" style="display:inline-block;padding-right:4px;vertical-align:middle" target="_blank"><img src="https://icon.signature.email/social/facebook-rounded-medium-FFFFFF-333333.png" width="32" height="32" border="0" alt="Facebook" style="border:0px;display:inline-block"></a><a href="https://www.instagram.com/DWphotoNY/" style="display:inline-block;padding-right:4px;vertical-align:middle" target="_blank"><img src="https://icon.signature.email/social/instagram-rounded-medium-FFFFFF-333333.png" width="32" height="32" border="0" alt="Instagram" style="border:0px;display:inline-block"></a></p></td></tr></tbody></table></div></div></div>
"""#
}
