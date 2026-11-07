# License agreement (custom EULA) for App Store Connect

App Store Connect › App Information › License Agreement › **Custom**: paste the text between the lines. It replaces
Apple's standard EULA, whose terms (no modification, no reverse engineering, no redistribution) conflict with the
LGPL v2.1 that covers the FFmpeg libraries in the app (section 6 requires terms that permit modification and
reverse engineering for debugging such modifications). The custom EULA therefore keeps Apple's required minimum
terms for the app as delivered by the App Store and excludes the open-source parts.

**Get legal sign-off before the first release** (see `legal-review.md`): whether the LGPL's relinking requirement is
met by an App Store app is an open question that companies answer differently.

---

```
FLUXO END USER LICENSE AGREEMENT

1. Parties and scope. This agreement is between you and Gianluca Lofrumento ("the Developer"), not Apple Inc.
("Apple"). It covers the copy of Fluxo you obtained from the App Store ("the App"). The Developer, not Apple, is
solely responsible for the App and its content.

2. Open-source components are not covered. The App's own source code is published under the MIT License
(https://github.com/glofru/Fluxo/blob/main/LICENSE). The App includes third-party software under its own licenses,
listed with their full texts in Settings > About > Acknowledgements, in particular the FFmpeg libraries
(FFmpeg.framework), licensed under the GNU Lesser General Public License version 2.1 or later ("LGPL"). Nothing in
this agreement limits the rights the MIT License, the LGPL or any other of those licenses give you. For the FFmpeg
libraries, the LGPL alone applies: you may copy, modify and redistribute them, and reverse engineer the App for
debugging such modifications, as the LGPL permits. The FFmpeg source code and the script that builds the libraries
are available at https://github.com/glofru/Fluxo/tree/main/Vendor/FFmpeg.

3. License. Subject to section 2, the Developer grants you a non-transferable license to use the App on any Apple
device you own or control, as permitted by the Usage Rules of the Apple Media Services Terms and Conditions.

4. Content. The App does not provide any channels, movies, series, TV guides or other content. You are solely
responsible for the playlists and guides you add and for having the right to watch, record and download what they
point to. Recordings and downloads are for your personal viewing only.

5. No warranty. The App is provided "as is", without warranty of any kind. To the extent permitted by law, the
Developer disclaims all warranties, express or implied. If the App fails to conform to any applicable warranty, you
may notify Apple, and Apple will refund the purchase price, if any; to the maximum extent permitted by law, Apple
has no other warranty obligation with respect to the App.

6. Limitation of liability. To the extent permitted by law, the Developer is not liable for any indirect,
incidental or consequential damages arising from your use of the App.

7. Product claims. The Developer, not Apple, is responsible for addressing any claims by you or a third party
relating to the App, including product liability claims, claims that the App fails to conform to any legal or
regulatory requirement, and claims under consumer protection, privacy or similar laws.

8. Intellectual property. In the event of a third-party claim that the App or your use of it infringes that third
party's intellectual property rights, the Developer, not Apple, is solely responsible for the investigation,
defense, settlement and discharge of the claim.

9. Maintenance and support. The Developer is solely responsible for maintenance and support, at
https://github.com/glofru/Fluxo/issues. Apple has no obligation to furnish any maintenance or support.

10. Legal compliance. You represent that you are not located in a country subject to a U.S. Government embargo or
designated as a "terrorist supporting" country, and that you are not on any U.S. Government list of prohibited or
restricted parties.

11. Third-party terms. You must comply with the terms of any third-party service you use with the App, including
your content providers and, when casting, Google's terms.

12. Third-party beneficiary. Apple and its subsidiaries are third-party beneficiaries of this agreement and, upon
your acceptance, have the right to enforce it against you as a third-party beneficiary.
```
