// Hand Google sign-in results back to the csTimer iOS app.
// The app starts Google sign-in with state=cstimer-ios in a system auth session; Google
// redirects here with #access_token=...&state=cstimer-ios, and this forwards the fragment
// to the app's callback scheme, which closes the session. Browsers never add that state,
// so normal web logins are unaffected.
// Load it in index.php's <head>, before csTimer's own scripts:
//   <script type="text/javascript" src="js/app-auth.js"></script>
(function () {
	var h = location.hash;
	if (/[#&]state=cstimer-ios(&|$)/.test(h) && /[#&]access_token=/.test(h)) {
		location.replace('cstimerbt://auth' + h);
	}
})();
