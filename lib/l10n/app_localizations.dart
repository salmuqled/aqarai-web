import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en')
  ];

  /// Home welcome message
  ///
  /// In en, this message translates to:
  /// **'Welcome to Aqar Ai'**
  String get welcomeMessage;

  /// Search results title
  ///
  /// In en, this message translates to:
  /// **'Search Results'**
  String get searchResults;

  /// Helper text for search
  ///
  /// In en, this message translates to:
  /// **'Enter area to search'**
  String get enterAreaToSearch;

  /// Select area
  ///
  /// In en, this message translates to:
  /// **'Select Area'**
  String get selectArea;

  /// Alert: select governorate first
  ///
  /// In en, this message translates to:
  /// **'Please select governorate and area first'**
  String get selectGovernorateAndArea;

  /// Smart assistant banner title on home
  ///
  /// In en, this message translates to:
  /// **'Ask about any property in Kuwait'**
  String get smartAssistantCtaTitle;

  /// Subtitle under smart assistant banner
  ///
  /// In en, this message translates to:
  /// **'Your smart real estate assistant'**
  String get smartAssistantCtaSubtitle;

  /// Type of property
  ///
  /// In en, this message translates to:
  /// **'Property Type'**
  String get propertyType;

  /// Apartment
  ///
  /// In en, this message translates to:
  /// **'Apartment'**
  String get propertyType_apartment;

  /// House
  ///
  /// In en, this message translates to:
  /// **'House'**
  String get propertyType_house;

  /// Building
  ///
  /// In en, this message translates to:
  /// **'Building'**
  String get propertyType_building;

  /// Land
  ///
  /// In en, this message translates to:
  /// **'Land'**
  String get propertyType_land;

  /// Industrial land
  ///
  /// In en, this message translates to:
  /// **'Industrial Land'**
  String get propertyType_industrialLand;

  /// Shop
  ///
  /// In en, this message translates to:
  /// **'Shop'**
  String get propertyType_shop;

  /// Office
  ///
  /// In en, this message translates to:
  /// **'Office'**
  String get propertyType_office;

  /// Chalet
  ///
  /// In en, this message translates to:
  /// **'Chalet'**
  String get propertyType_chalet;

  /// For sale
  ///
  /// In en, this message translates to:
  /// **'For Sale'**
  String get forSale;

  /// For rent
  ///
  /// In en, this message translates to:
  /// **'For Rent'**
  String get forRent;

  /// Exchange
  ///
  /// In en, this message translates to:
  /// **'Exchange'**
  String get forExchange;

  /// Search button
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// Chalets section
  ///
  /// In en, this message translates to:
  /// **'Chalets'**
  String get chalets;

  /// Wanted section
  ///
  /// In en, this message translates to:
  /// **'Wanted'**
  String get wanted;

  /// Wanted list
  ///
  /// In en, this message translates to:
  /// **'Wanted Requests'**
  String get wantedList;

  /// Section title for user's wanted requests in My Ads
  ///
  /// In en, this message translates to:
  /// **'My Wanted Requests'**
  String get myWantedRequests;

  /// Add wanted request
  ///
  /// In en, this message translates to:
  /// **'Post Request'**
  String get postWanted;

  /// Request description
  ///
  /// In en, this message translates to:
  /// **'Request Description'**
  String get propertyDescription;

  /// Login required
  ///
  /// In en, this message translates to:
  /// **'You must log in to continue'**
  String get errorMessagePlaceholder;

  /// Valuation page title
  ///
  /// In en, this message translates to:
  /// **'Property Valuation'**
  String get valuation;

  /// Valuation subtitle
  ///
  /// In en, this message translates to:
  /// **'Please fill out the following details to submit your request'**
  String get valuation_subtitle;

  /// Owner name
  ///
  /// In en, this message translates to:
  /// **'Owner Name'**
  String get valuation_ownerName;

  /// Phone number
  ///
  /// In en, this message translates to:
  /// **'Phone Number'**
  String get valuation_phone;

  /// Governorate
  ///
  /// In en, this message translates to:
  /// **'Governorate'**
  String get valuation_governorate;

  /// Area
  ///
  /// In en, this message translates to:
  /// **'Area'**
  String get valuation_area;

  /// Type
  ///
  /// In en, this message translates to:
  /// **'Property Type'**
  String get valuation_propertyType;

  /// Size
  ///
  /// In en, this message translates to:
  /// **'Property Size (m²)'**
  String get valuation_propertyArea;

  /// Build year
  ///
  /// In en, this message translates to:
  /// **'Build Year'**
  String get valuation_buildYear;

  /// Condition
  ///
  /// In en, this message translates to:
  /// **'Condition'**
  String get valuation_condition;

  /// New
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get valuation_condition_new;

  /// Very good
  ///
  /// In en, this message translates to:
  /// **'Very Good'**
  String get valuation_condition_veryGood;

  /// Good
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get valuation_condition_good;

  /// Needs work
  ///
  /// In en, this message translates to:
  /// **'Needs Renovation'**
  String get valuation_condition_needsWork;

  /// Purpose
  ///
  /// In en, this message translates to:
  /// **'Purpose'**
  String get valuation_purpose;

  /// Sale
  ///
  /// In en, this message translates to:
  /// **'For Sale'**
  String get valuation_purpose_sale;

  /// Rent
  ///
  /// In en, this message translates to:
  /// **'For Rent'**
  String get valuation_purpose_rent;

  /// Mortgage
  ///
  /// In en, this message translates to:
  /// **'Mortgage'**
  String get valuation_purpose_mortgage;

  /// Market evaluation
  ///
  /// In en, this message translates to:
  /// **'Market Evaluation'**
  String get valuation_purpose_market;

  /// Notes
  ///
  /// In en, this message translates to:
  /// **'Additional Notes'**
  String get valuation_notes;

  /// Submit button
  ///
  /// In en, this message translates to:
  /// **'Submit Valuation Request'**
  String get valuation_submit;

  /// Saved
  ///
  /// In en, this message translates to:
  /// **'Valuation request submitted successfully'**
  String get valuation_saved;

  /// Error
  ///
  /// In en, this message translates to:
  /// **'An error occurred while submitting the request'**
  String get valuation_error;

  /// Required field
  ///
  /// In en, this message translates to:
  /// **'This field is required'**
  String get valuation_required;

  /// Apartment
  ///
  /// In en, this message translates to:
  /// **'Apartment'**
  String get valuation_type_apartment;

  /// Villa
  ///
  /// In en, this message translates to:
  /// **'Villa'**
  String get valuation_type_villa;

  /// Land
  ///
  /// In en, this message translates to:
  /// **'Land'**
  String get valuation_type_land;

  /// Commercial
  ///
  /// In en, this message translates to:
  /// **'Commercial'**
  String get valuation_type_commercial;

  /// Add property button
  ///
  /// In en, this message translates to:
  /// **'Add Property'**
  String get addProperty;

  /// Admin follow up
  ///
  /// In en, this message translates to:
  /// **'Ads Review'**
  String get adminFollowup;

  /// Approve button
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get approve;

  /// Reject button
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get reject;

  /// Price
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get propertyPrice;

  /// Size
  ///
  /// In en, this message translates to:
  /// **'Size (m²)'**
  String get propertySize;

  /// Choose image
  ///
  /// In en, this message translates to:
  /// **'Choose Property Image'**
  String get choosePropertyImage;

  /// Number of rooms
  ///
  /// In en, this message translates to:
  /// **'Rooms'**
  String get roomCount;

  /// Master rooms
  ///
  /// In en, this message translates to:
  /// **'Master Rooms'**
  String get masterRoomCount;

  /// Bathrooms
  ///
  /// In en, this message translates to:
  /// **'Bathrooms'**
  String get bathroomCount;

  /// Parking spots
  ///
  /// In en, this message translates to:
  /// **'Parking Spots'**
  String get parkingCount;

  /// Elevator
  ///
  /// In en, this message translates to:
  /// **'Elevator'**
  String get hasElevator;

  /// Central AC
  ///
  /// In en, this message translates to:
  /// **'Central AC'**
  String get hasCentralAC;

  /// Split AC
  ///
  /// In en, this message translates to:
  /// **'Split AC'**
  String get hasSplitAC;

  /// Maid room
  ///
  /// In en, this message translates to:
  /// **'Maid Room'**
  String get hasMaidRoom;

  /// Driver room
  ///
  /// In en, this message translates to:
  /// **'Driver Room'**
  String get hasDriverRoom;

  /// Laundry room
  ///
  /// In en, this message translates to:
  /// **'Laundry Room'**
  String get hasLaundryRoom;

  /// Garden
  ///
  /// In en, this message translates to:
  /// **'Garden'**
  String get hasGarden;

  /// Description
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get description;

  /// Publish button
  ///
  /// In en, this message translates to:
  /// **'Publish Property'**
  String get publishProperty;

  /// Publishing
  ///
  /// In en, this message translates to:
  /// **'Publishing...'**
  String get publishing;

  /// Before terms link on add property
  ///
  /// In en, this message translates to:
  /// **'I agree to the '**
  String get addPropertyTermsLead;

  /// Terms link label
  ///
  /// In en, this message translates to:
  /// **'Terms and Conditions'**
  String get addPropertyTermsLink;

  /// Toast when publishing without acceptance
  ///
  /// In en, this message translates to:
  /// **'Please accept the terms and conditions before publishing.'**
  String get addPropertyTermsMustAccept;

  /// Terms dialog title
  ///
  /// In en, this message translates to:
  /// **'Property Listing Agreement — AqarAi'**
  String get addPropertyTermsDialogTitle;

  /// Full property listing terms (English)
  ///
  /// In en, this message translates to:
  /// **'Property Listing Terms and Conditions — AqarAi Platform\n\nIntroduction:\nThese terms and conditions constitute a legally binding agreement between a user of the AqarAi platform (the advertiser) and the platform administration. By tapping \"I agree\" or \"Publish property\", the user acknowledges that they have read, understood, and agree to comply with all of the following provisions:\n\n1. Advertiser capacity and accuracy of data:\n• Ownership and agency: The advertiser warrants that they are the lawful owner of the listed property, or a licensed real estate office with valid authorization or a marketing agreement in effect from the owner.\n• Accuracy of information: The advertiser confirms that all property details (area, location, price, legal status) are fully accurate and reflect reality.\n• Images: Attached images must be genuine images of the same property. Stock images or images of other properties are strictly prohibited; the platform may remove the listing if misleading images are proven.\n\n2. Commissions and fees (brokerage policy):\n• Sale commission: Upon completion of a sale, the advertiser/seller undertakes to pay a commission of 1% of the total sold property value to AqarAi.\n• Rental commission: Upon completion of a rental, the advertiser/landlord undertakes to pay a commission equal to half of one month\'s rent once, to the platform.\n• Commission evasion: Any attempt to complete a transaction off-platform to avoid paying commission may subject the account holder to legal action and recovery of the due commission, as well as permanent account suspension.\n\n3. Featured listings and paid services:\n• \"Featured listing\" fees are for a technical service to increase visibility in designated areas of the app; the platform does not guarantee that a sale or lease will occur.\n• Amounts paid for featuring listings are non-refundable once the service is activated and the listing appears.\n\n4. Exchange and AI property valuation:\n• Exchange: The platform\'s responsibility is limited to connecting parties interested in exchange; it assumes no legal liability for the validity of exchanged properties or transfer procedures.\n• AI valuation: The user acknowledges that the appraisal service provided via artificial intelligence is indicative and approximate, based on current market data, and is not an official valuation approved by government or banking authorities.\n\n5. Platform disclaimer:\n• AqarAi is a technical intermediary only and assumes no liability for disputes between advertiser and buyer/tenant, or for property quality or hidden defects.\n• On-site inspection and verification of title deeds and official documents are solely the responsibility of the contracting parties.\n\n6. Amendment and removal:\n• AqarAi administration reserves the right to amend these terms at any time and to delete any listing or suspend any account that violates these policies without prior notice.'**
  String get addPropertyTermsDialogBody;

  /// Close terms dialog
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get addPropertyTermsDialogClose;

  /// No items
  ///
  /// In en, this message translates to:
  /// **'No items found'**
  String get noWantedItems;

  /// Matches
  ///
  /// In en, this message translates to:
  /// **'Matches'**
  String get matches;

  /// Expired
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get expired;

  /// Area
  ///
  /// In en, this message translates to:
  /// **'Area'**
  String get areaLabel;

  /// Block
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get blockLabel;

  /// Matched date
  ///
  /// In en, this message translates to:
  /// **'Matched On'**
  String get matched;

  /// Budget
  ///
  /// In en, this message translates to:
  /// **'Budget'**
  String get budget;

  /// Price
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get price;

  /// Type
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get type;

  /// Login button
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get login;

  /// Post
  ///
  /// In en, this message translates to:
  /// **'Post'**
  String get post;

  /// Retry
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// Minimum price
  ///
  /// In en, this message translates to:
  /// **'Min Price'**
  String get minPrice;

  /// Maximum price
  ///
  /// In en, this message translates to:
  /// **'Max Price'**
  String get maxPrice;

  /// Saved
  ///
  /// In en, this message translates to:
  /// **'Saved successfully'**
  String get requestSaved;

  /// Error
  ///
  /// In en, this message translates to:
  /// **'An error occurred while saving request'**
  String get requestError;

  /// Properties in area
  ///
  /// In en, this message translates to:
  /// **'Properties in {area}'**
  String propertiesInArea(String area);

  /// Search results per area
  ///
  /// In en, this message translates to:
  /// **'Search results for {area}'**
  String searchResultsForArea(String area);

  /// No description provided for @myAds.
  ///
  /// In en, this message translates to:
  /// **'My Ads'**
  String get myAds;

  /// No description provided for @favorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favorites;

  /// No description provided for @favoritesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No saved properties.'**
  String get favoritesEmpty;

  /// Bottom sheet title for favorites and language
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get quickMenuTitle;

  /// Open privacy policy and terms from quick menu
  ///
  /// In en, this message translates to:
  /// **'Privacy & Terms'**
  String get quickMenuLegal;

  /// Title for privacy and terms screen
  ///
  /// In en, this message translates to:
  /// **'Legal information'**
  String get legalScreenTitle;

  /// Privacy policy tab
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get legalTabPrivacy;

  /// Terms of service tab
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get legalTabTerms;

  /// No description provided for @languageLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageLabel;

  /// No description provided for @languageArabic.
  ///
  /// In en, this message translates to:
  /// **'Arabic'**
  String get languageArabic;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @active.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get active;

  /// No description provided for @expiredAds.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get expiredAds;

  /// No description provided for @featuredAds.
  ///
  /// In en, this message translates to:
  /// **'Featured'**
  String get featuredAds;

  /// Section title for featured wanted requests
  ///
  /// In en, this message translates to:
  /// **'Featured Wanted'**
  String get featuredWanted;

  /// No description provided for @addedOn.
  ///
  /// In en, this message translates to:
  /// **'Added On'**
  String get addedOn;

  /// No description provided for @expiresOn.
  ///
  /// In en, this message translates to:
  /// **'Expires On'**
  String get expiresOn;

  /// No description provided for @endsIn.
  ///
  /// In en, this message translates to:
  /// **'Ends In'**
  String get endsIn;

  /// No description provided for @days.
  ///
  /// In en, this message translates to:
  /// **'days'**
  String get days;

  /// No description provided for @featuredUntil.
  ///
  /// In en, this message translates to:
  /// **'Featured Until'**
  String get featuredUntil;

  /// No description provided for @makeFeatured.
  ///
  /// In en, this message translates to:
  /// **'Make Featured'**
  String get makeFeatured;

  /// No description provided for @extendFeature.
  ///
  /// In en, this message translates to:
  /// **'Extend Feature'**
  String get extendFeature;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @hardDeleteWarning.
  ///
  /// In en, this message translates to:
  /// **'This ad will be permanently deleted'**
  String get hardDeleteWarning;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// Logout
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logout;

  /// Logout confirmation
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to logout?'**
  String get logoutConfirm;

  /// Logout success
  ///
  /// In en, this message translates to:
  /// **'Logged out successfully'**
  String get logoutSuccess;

  /// Login title
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get loginTitle;

  /// Email
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// Password
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// Forgot password
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get forgotPassword;

  /// Google button
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get continueWithGoogle;

  /// Apple button
  ///
  /// In en, this message translates to:
  /// **'Continue with Apple'**
  String get continueWithApple;

  /// Create account
  ///
  /// In en, this message translates to:
  /// **'Create a new account'**
  String get createAccount;

  /// Full name
  ///
  /// In en, this message translates to:
  /// **'Full Name'**
  String get fullName;

  /// No description provided for @or.
  ///
  /// In en, this message translates to:
  /// **'OR'**
  String get or;

  /// No description provided for @noAccount.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account?'**
  String get noAccount;

  /// Sign up with email button
  ///
  /// In en, this message translates to:
  /// **'Sign up with email'**
  String get signUpWithEmail;

  /// Sign in with email link
  ///
  /// In en, this message translates to:
  /// **'Sign in with email'**
  String get signInWithEmail;

  /// Already have account
  ///
  /// In en, this message translates to:
  /// **'Already have an account?'**
  String get haveAccount;

  /// Password mismatch message
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get passwordsDoNotMatch;

  /// Confirm password
  ///
  /// In en, this message translates to:
  /// **'Confirm Password'**
  String get confirmPassword;

  /// Send reset link
  ///
  /// In en, this message translates to:
  /// **'Send reset link'**
  String get sendResetLink;

  /// Reset password description
  ///
  /// In en, this message translates to:
  /// **'Enter your email and we will send you a reset link'**
  String get resetPasswordDesc;

  /// Property details page title
  ///
  /// In en, this message translates to:
  /// **'Property Details'**
  String get propertyDetails;

  /// Owner info section
  ///
  /// In en, this message translates to:
  /// **'Owner Information'**
  String get ownerInfo;

  /// Visible only for admin
  ///
  /// In en, this message translates to:
  /// **'Owner Info (Admin Only)'**
  String get ownerOnlyAdmin;

  /// Type label
  ///
  /// In en, this message translates to:
  /// **'Property Type'**
  String get typeLabel;

  /// Service type label
  ///
  /// In en, this message translates to:
  /// **'Service Type'**
  String get serviceTypeLabel;

  /// Ad status
  ///
  /// In en, this message translates to:
  /// **'Ad Status'**
  String get statusLabel;

  /// Property features
  ///
  /// In en, this message translates to:
  /// **'Features'**
  String get features;

  /// Property description
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get descriptionLabel;

  /// No description
  ///
  /// In en, this message translates to:
  /// **'No description available'**
  String get noDescription;

  /// Call owner button
  ///
  /// In en, this message translates to:
  /// **'Call Owner'**
  String get callOwner;

  /// Added on date
  ///
  /// In en, this message translates to:
  /// **'Added On:'**
  String get addedOnDate;

  /// Owner name
  ///
  /// In en, this message translates to:
  /// **'Owner Name'**
  String get ownerNameLabel;

  /// Owner phone number
  ///
  /// In en, this message translates to:
  /// **'Owner Phone'**
  String get ownerPhoneLabel;

  /// Ad identifier
  ///
  /// In en, this message translates to:
  /// **'Ad ID'**
  String get adIdLabel;

  /// Service type in chalet search
  ///
  /// In en, this message translates to:
  /// **'Service Type'**
  String get serviceType;

  /// Service: sale
  ///
  /// In en, this message translates to:
  /// **'For Sale'**
  String get sale;

  /// Service: rent
  ///
  /// In en, this message translates to:
  /// **'For Rent'**
  String get rent;

  /// Service: exchange
  ///
  /// In en, this message translates to:
  /// **'Exchange'**
  String get exchange;

  /// Button: interested in property
  ///
  /// In en, this message translates to:
  /// **'I\'m interested'**
  String get imInterested;

  /// Admin section for interested leads
  ///
  /// In en, this message translates to:
  /// **'Interested'**
  String get interestedDetails;

  /// Default ad title
  ///
  /// In en, this message translates to:
  /// **'Ad'**
  String get adLabel;

  /// Message after sending reset link
  ///
  /// In en, this message translates to:
  /// **'Password reset link has been sent to your email'**
  String get passwordResetSent;

  /// Message after featuring ad
  ///
  /// In en, this message translates to:
  /// **'Ad featured for 7 days'**
  String get adFeaturedSevenDays;

  /// Error word for display with details
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get errorLabel;

  /// Message after submitting property for review
  ///
  /// In en, this message translates to:
  /// **'Property sent for review'**
  String get propertySentForReview;

  /// Admin moderation menu label
  ///
  /// In en, this message translates to:
  /// **'Moderation'**
  String get moderationMenu;

  /// Ban user action
  ///
  /// In en, this message translates to:
  /// **'Ban user'**
  String get banUser;

  /// Confirm ban dialog title
  ///
  /// In en, this message translates to:
  /// **'Ban this user?'**
  String get banUserConfirmTitle;

  /// Confirm ban dialog body
  ///
  /// In en, this message translates to:
  /// **'They will be signed out, unable to log in, and cannot post new listings. This uses Firebase Auth disable and Firestore flags.'**
  String get banUserConfirmMessage;

  /// After successful ban
  ///
  /// In en, this message translates to:
  /// **'User has been banned.'**
  String get banUserSuccess;

  /// Add property blocked for banned user
  ///
  /// In en, this message translates to:
  /// **'Your account is restricted. You cannot post listings.'**
  String get cannotPostBanned;

  /// Title when banned user session ends
  ///
  /// In en, this message translates to:
  /// **'Account restricted'**
  String get accountSuspendedTitle;

  /// Body when banned user session ends
  ///
  /// In en, this message translates to:
  /// **'This account is no longer allowed to use the app. Contact support if you think this is a mistake.'**
  String get accountSuspendedBody;

  /// Firebase Auth user-disabled on sign-in
  ///
  /// In en, this message translates to:
  /// **'This account has been disabled.'**
  String get loginUserDisabled;

  /// Support / contact page title
  ///
  /// In en, this message translates to:
  /// **'Contact us'**
  String get contactUsTitle;

  /// Intro on contact form
  ///
  /// In en, this message translates to:
  /// **'Send us feedback, report a problem, or ask about a listing. We read every message.'**
  String get supportFormIntro;

  /// Ticket subject field
  ///
  /// In en, this message translates to:
  /// **'Subject'**
  String get supportSubjectLabel;

  /// Subject hint
  ///
  /// In en, this message translates to:
  /// **'Short summary'**
  String get supportSubjectHint;

  /// Ticket category
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get supportCategoryLabel;

  /// Ticket body
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get supportMessageLabel;

  /// Message hint
  ///
  /// In en, this message translates to:
  /// **'Describe your issue or question…'**
  String get supportMessageHint;

  /// Submit support ticket
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get supportSubmit;

  /// After ticket submitted
  ///
  /// In en, this message translates to:
  /// **'Message sent successfully. We will get back to you soon.'**
  String get supportMessageSent;

  /// Validation on contact form
  ///
  /// In en, this message translates to:
  /// **'Please enter subject and message.'**
  String get supportFillRequired;

  /// Support category
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get supportCategoryGeneral;

  /// Support category
  ///
  /// In en, this message translates to:
  /// **'Bug / technical issue'**
  String get supportCategoryBug;

  /// Support category
  ///
  /// In en, this message translates to:
  /// **'Property inquiry'**
  String get supportCategoryPropertyInquiry;

  /// Support category
  ///
  /// In en, this message translates to:
  /// **'Payment'**
  String get supportCategoryPayment;

  /// Admin tab EN
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get supportTabEn;

  /// Admin tab AR
  ///
  /// In en, this message translates to:
  /// **'الدعم'**
  String get supportTabAr;

  /// Ticket status
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get supportTicketStatusOpen;

  /// Ticket status
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get supportTicketStatusInProgress;

  /// Ticket status
  ///
  /// In en, this message translates to:
  /// **'Resolved'**
  String get supportTicketStatusResolved;

  /// Admin ticket action
  ///
  /// In en, this message translates to:
  /// **'Mark in progress'**
  String get supportMarkInProgress;

  /// Admin ticket action
  ///
  /// In en, this message translates to:
  /// **'Mark resolved'**
  String get supportMarkResolved;

  /// Admin delete ticket
  ///
  /// In en, this message translates to:
  /// **'Delete ticket'**
  String get supportDeleteTicket;

  /// Confirm delete ticket
  ///
  /// In en, this message translates to:
  /// **'Remove this ticket from the list? This cannot be undone.'**
  String get supportDeleteTicketConfirm;

  /// Empty admin support list
  ///
  /// In en, this message translates to:
  /// **'No support tickets yet.'**
  String get supportNoTickets;

  /// Label before user name on ticket
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get supportUserLine;

  /// After admin status change
  ///
  /// In en, this message translates to:
  /// **'Ticket updated.'**
  String get supportTicketUpdated;

  /// After admin deleted ticket
  ///
  /// In en, this message translates to:
  /// **'Ticket deleted.'**
  String get supportTicketDeleted;

  /// Admin generate post dialog
  ///
  /// In en, this message translates to:
  /// **'Instagram post image'**
  String get instagramPostDialogTitle;

  /// Explain template + no preview
  ///
  /// In en, this message translates to:
  /// **'Text is drawn on the server over your 1080×1080 template. The image is not shown in the app—open the link in a browser.'**
  String get instagramPostDialogHint;

  /// Overlay title
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get instagramPostFieldTitle;

  /// Overlay subtitle
  ///
  /// In en, this message translates to:
  /// **'Subtitle'**
  String get instagramPostFieldSubtitle;

  /// Trigger Cloud Function
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get instagramPostGenerate;

  /// Validation
  ///
  /// In en, this message translates to:
  /// **'Enter title and subtitle.'**
  String get instagramPostFillBoth;

  /// Loading
  ///
  /// In en, this message translates to:
  /// **'Generating image…'**
  String get instagramPostGenerating;

  /// Callable error
  ///
  /// In en, this message translates to:
  /// **'Could not generate image. Check template in Storage and try again.'**
  String get instagramPostFailed;

  /// After success
  ///
  /// In en, this message translates to:
  /// **'Image ready'**
  String get instagramPostSuccessTitle;

  /// Success message no preview
  ///
  /// In en, this message translates to:
  /// **'📎 Image created. Open in browser or copy the link. Nothing is shown inside the app.'**
  String get instagramPostSuccessBody;

  /// Launch URL
  ///
  /// In en, this message translates to:
  /// **'Open in browser'**
  String get instagramPostOpenBrowser;

  /// Clipboard
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get instagramPostCopyLink;

  /// Snackbar
  ///
  /// In en, this message translates to:
  /// **'Link copied.'**
  String get instagramPostLinkCopied;

  /// url_launcher failed
  ///
  /// In en, this message translates to:
  /// **'Could not open link.'**
  String get instagramPostOpenFailed;

  /// Admin dashboard icon
  ///
  /// In en, this message translates to:
  /// **'Generate Instagram image'**
  String get instagramPostAppBarTooltip;

  /// Caption area field
  ///
  /// In en, this message translates to:
  /// **'Area (for caption)'**
  String get instagramPostFieldArea;

  /// Caption property type
  ///
  /// In en, this message translates to:
  /// **'Property type (for caption)'**
  String get instagramPostFieldPropertyType;

  /// Validation all fields
  ///
  /// In en, this message translates to:
  /// **'Enter title, subtitle, area, and property type.'**
  String get instagramPostFillAllFields;

  /// After image+caption ready
  ///
  /// In en, this message translates to:
  /// **'📎 Post ready'**
  String get instagramPostCreatedHeadline;

  /// Caption section label
  ///
  /// In en, this message translates to:
  /// **'Suggested caption'**
  String get instagramPostCaptionPreviewLabel;

  /// Open image URL in browser
  ///
  /// In en, this message translates to:
  /// **'Open image'**
  String get instagramPostOpenImage;

  /// Clipboard caption
  ///
  /// In en, this message translates to:
  /// **'Copy caption'**
  String get instagramPostCopyCaption;

  /// Deep link or web
  ///
  /// In en, this message translates to:
  /// **'Open Instagram'**
  String get instagramPostOpenInstagram;

  /// Snackbar after copy caption
  ///
  /// In en, this message translates to:
  /// **'Caption copied'**
  String get instagramCaptionCopied;

  /// Launch failure
  ///
  /// In en, this message translates to:
  /// **'Could not open Instagram.'**
  String get instagramOpenAppFailed;

  /// Missing URL hint
  ///
  /// In en, this message translates to:
  /// **'No image URL — open image is disabled.'**
  String get instagramPostNoImageUrl;

  /// Demand level field label
  ///
  /// In en, this message translates to:
  /// **'Market demand (for caption)'**
  String get instagramDemandLevelLabel;

  /// High demand segment
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get instagramDemandHigh;

  /// Medium demand segment
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get instagramDemandMedium;

  /// Low demand segment
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get instagramDemandLow;

  /// Deals count for caption
  ///
  /// In en, this message translates to:
  /// **'Recent closed deals (optional)'**
  String get instagramRecentDealsLabel;

  /// Deals field hint
  ///
  /// In en, this message translates to:
  /// **'0 if unknown'**
  String get instagramRecentDealsHint;

  /// Area analytics card title
  ///
  /// In en, this message translates to:
  /// **'💡 Market insight'**
  String get instagramAreaAnalyticsHeadline;

  /// Demand line with localized level label
  ///
  /// In en, this message translates to:
  /// **'📊 Demand: {level}'**
  String instagramAreaAnalyticsDemand(String level);

  /// Recent closed deals count
  ///
  /// In en, this message translates to:
  /// **'📈 Deals (7 days): {count}'**
  String instagramAreaAnalyticsDeals(int count);

  /// Analytics loading
  ///
  /// In en, this message translates to:
  /// **'Loading market data…'**
  String get instagramAreaAnalyticsLoading;

  /// Analytics fetch failed
  ///
  /// In en, this message translates to:
  /// **'Could not load analytics. Defaults are used — you can override below.'**
  String get instagramAreaAnalyticsError;

  /// Reload area analytics button
  ///
  /// In en, this message translates to:
  /// **'Refresh insight'**
  String get instagramAreaAnalyticsRefresh;

  /// Hint when area empty
  ///
  /// In en, this message translates to:
  /// **'Enter an area name to load 7-day deal stats.'**
  String get instagramAreaAnalyticsEnterArea;

  /// Caption fields override subtitle
  ///
  /// In en, this message translates to:
  /// **'Auto-filled from data — adjust if needed'**
  String get instagramDemandOverrideHint;

  /// Generate 4-slide carousel
  ///
  /// In en, this message translates to:
  /// **'Carousel (4 images)'**
  String get instagramPostGenerateCarousel;

  /// Loading carousel
  ///
  /// In en, this message translates to:
  /// **'Generating carousel…'**
  String get instagramPostGeneratingCarousel;

  /// Carousel callable error
  ///
  /// In en, this message translates to:
  /// **'Could not generate carousel. Check template in Storage and try again.'**
  String get instagramPostCarouselFailed;

  /// Carousel success headline
  ///
  /// In en, this message translates to:
  /// **'📎 Post ready ({count} images)'**
  String instagramPostCarouselHeadline(int count);

  /// Open carousel slides
  ///
  /// In en, this message translates to:
  /// **'Open images'**
  String get instagramPostOpenImages;

  /// Carousel slide picker row
  ///
  /// In en, this message translates to:
  /// **'Slide {slideNumber}'**
  String instagramCarouselSlideLabel(int slideNumber);

  /// Carousel validation (subtitle optional)
  ///
  /// In en, this message translates to:
  /// **'Enter title, area, and property type for the carousel.'**
  String get instagramPostCarouselFillFields;

  /// A/B caption section title
  ///
  /// In en, this message translates to:
  /// **'💡 Best suggested caption'**
  String get instagramCaptionVariantBestTitle;

  /// Caption variant A label
  ///
  /// In en, this message translates to:
  /// **'Variant A · Urgency'**
  String get instagramCaptionVariantRowA;

  /// Caption variant B label
  ///
  /// In en, this message translates to:
  /// **'Variant B · Value'**
  String get instagramCaptionVariantRowB;

  /// Caption variant C label
  ///
  /// In en, this message translates to:
  /// **'Variant C · Steady market'**
  String get instagramCaptionVariantRowC;

  /// Apply and copy top-scored caption
  ///
  /// In en, this message translates to:
  /// **'Use best'**
  String get instagramCaptionVariantUseBest;

  /// Hint to use cards
  ///
  /// In en, this message translates to:
  /// **'Pick manually'**
  String get instagramCaptionVariantManualPick;

  /// Snackbar for manual pick
  ///
  /// In en, this message translates to:
  /// **'Tap a card below, then Copy caption.'**
  String get instagramCaptionVariantManualHint;

  /// Heuristic caption score
  ///
  /// In en, this message translates to:
  /// **'Score: {score}'**
  String instagramCaptionVariantScore(String score);

  /// For ?id= in caption URL
  ///
  /// In en, this message translates to:
  /// **'Property ID (tracking link, optional)'**
  String get instagramPostPropertyIdOptional;

  /// Hint for tracking field
  ///
  /// In en, this message translates to:
  /// **'Firestore document id — adds ?id=…&cid=A|B|C'**
  String get instagramPostPropertyIdHint;

  /// Marketing auto-decision dialog title
  ///
  /// In en, this message translates to:
  /// **'💡 Smart recommendation'**
  String get autoDecisionTitle;

  /// Suggested send hour
  ///
  /// In en, this message translates to:
  /// **'🕒 Best time: {time}'**
  String autoDecisionBestTime(String time);

  /// Suggested FCM segment
  ///
  /// In en, this message translates to:
  /// **'🎯 Audience: {segment}'**
  String autoDecisionAudience(String segment);

  /// Chosen A/B/C caption
  ///
  /// In en, this message translates to:
  /// **'🔥 Caption: Variant {id}'**
  String autoDecisionCaptionVariant(String id);

  /// Rough expected click rate
  ///
  /// In en, this message translates to:
  /// **'📊 Expected CTR: {percent}%'**
  String autoDecisionExpectedCtr(int percent);

  /// Model confidence
  ///
  /// In en, this message translates to:
  /// **'📈 Confidence: {percent}%'**
  String autoDecisionConfidence(int percent);

  /// Label before explanation string
  ///
  /// In en, this message translates to:
  /// **'Reason:'**
  String get autoDecisionReasonLabel;

  /// Segment label
  ///
  /// In en, this message translates to:
  /// **'Active users'**
  String get autoDecisionAudienceActive;

  /// Segment label
  ///
  /// In en, this message translates to:
  /// **'Warm users'**
  String get autoDecisionAudienceWarm;

  /// Segment label
  ///
  /// In en, this message translates to:
  /// **'Cold users'**
  String get autoDecisionAudienceCold;

  /// Segment label
  ///
  /// In en, this message translates to:
  /// **'All users'**
  String get autoDecisionAudienceAll;

  /// Queue at suggested time
  ///
  /// In en, this message translates to:
  /// **'Approve & schedule'**
  String get autoDecisionApproveSchedule;

  /// Immediate broadcast
  ///
  /// In en, this message translates to:
  /// **'Send now'**
  String get autoDecisionSendNow;

  /// Open manual preview
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get autoDecisionEdit;

  /// High-confidence hybrid dialog title
  ///
  /// In en, this message translates to:
  /// **'🔥 Auto-run suggested'**
  String get hybridAutoTitle;

  /// High-confidence explainer
  ///
  /// In en, this message translates to:
  /// **'This decision has high confidence.'**
  String get hybridAutoSubtitle;

  /// Medium-confidence title
  ///
  /// In en, this message translates to:
  /// **'💡 Review required'**
  String get hybridReviewTitle;

  /// Low-confidence title
  ///
  /// In en, this message translates to:
  /// **'⚠️ Needs your input'**
  String get hybridManualTitle;

  /// Low-confidence explainer
  ///
  /// In en, this message translates to:
  /// **'Confidence is below the review threshold — edit before sending.'**
  String get hybridManualSubtitle;

  /// Send push immediately (auto tier)
  ///
  /// In en, this message translates to:
  /// **'Run now'**
  String get hybridRunNow;

  /// No description provided for @hybridAutoCountdown.
  ///
  /// In en, this message translates to:
  /// **'Auto-send in {seconds}s (cancel to stop)'**
  String hybridAutoCountdown(int seconds);

  /// Banner when auto shield blocks execution
  ///
  /// In en, this message translates to:
  /// **'🛑 Auto mode paused'**
  String get hybridAutoShieldPausedTitle;

  /// Explains auto shield
  ///
  /// In en, this message translates to:
  /// **'Automatic execution has been paused due to performance.'**
  String get hybridAutoShieldPausedBody;

  /// Manual tier single action
  ///
  /// In en, this message translates to:
  /// **'Edit only'**
  String get hybridEditOnly;

  /// Settings dialog title
  ///
  /// In en, this message translates to:
  /// **'Hybrid marketing'**
  String get hybridSettingsTitle;

  /// App bar icon
  ///
  /// In en, this message translates to:
  /// **'Hybrid marketing settings'**
  String get hybridSettingsTooltip;

  /// Toggle off by default
  ///
  /// In en, this message translates to:
  /// **'Enable automatic send (high confidence only)'**
  String get hybridSettingsAutoExec;

  /// Slider label
  ///
  /// In en, this message translates to:
  /// **'Auto threshold (high confidence)'**
  String get hybridSettingsAutoThreshold;

  /// Slider label
  ///
  /// In en, this message translates to:
  /// **'Review threshold (medium)'**
  String get hybridSettingsReviewThreshold;

  /// Persist prefs
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get hybridSettingsSave;

  /// Auto marketing recommendation vs admin action
  ///
  /// In en, this message translates to:
  /// **'📊 Decision accuracy'**
  String get adminDecisionAccuracyTitle;

  /// Explainer under title
  ///
  /// In en, this message translates to:
  /// **'Accepted vs modified smart recommendations (Instagram flow).'**
  String get adminDecisionAccuracySubtitle;

  /// No description provided for @adminDecisionAcceptedPct.
  ///
  /// In en, this message translates to:
  /// **'👍 Accepted: {pct}%'**
  String adminDecisionAcceptedPct(String pct);

  /// No description provided for @adminDecisionModifiedPct.
  ///
  /// In en, this message translates to:
  /// **'✏️ Modified: {pct}%'**
  String adminDecisionModifiedPct(String pct);

  /// No description provided for @adminDecisionMostOverridden.
  ///
  /// In en, this message translates to:
  /// **'Most edited: {part}'**
  String adminDecisionMostOverridden(String part);

  /// No description provided for @adminDecisionPartTime.
  ///
  /// In en, this message translates to:
  /// **'time'**
  String get adminDecisionPartTime;

  /// No description provided for @adminDecisionPartCaption.
  ///
  /// In en, this message translates to:
  /// **'caption'**
  String get adminDecisionPartCaption;

  /// No description provided for @adminDecisionPartAudience.
  ///
  /// In en, this message translates to:
  /// **'audience'**
  String get adminDecisionPartAudience;

  /// No description provided for @adminDecisionPatternTrust.
  ///
  /// In en, this message translates to:
  /// **'Pattern trust: {pct}%'**
  String adminDecisionPatternTrust(String pct);

  /// Empty state
  ///
  /// In en, this message translates to:
  /// **'No decisions logged yet.'**
  String get adminDecisionNoLogs;

  /// Per-dimension trust heading
  ///
  /// In en, this message translates to:
  /// **'📊 System trust'**
  String get adminDecisionSystemTrustTitle;

  /// No description provided for @adminDecisionTrustCaptionLine.
  ///
  /// In en, this message translates to:
  /// **'🔥 Caption: {pct}%'**
  String adminDecisionTrustCaptionLine(String pct);

  /// No description provided for @adminDecisionTrustTimeLine.
  ///
  /// In en, this message translates to:
  /// **'🕒 Time: {pct}%'**
  String adminDecisionTrustTimeLine(String pct);

  /// No description provided for @adminDecisionTrustAudienceLine.
  ///
  /// In en, this message translates to:
  /// **'🎯 Audience: {pct}%'**
  String adminDecisionTrustAudienceLine(String pct);

  /// No description provided for @adminDecisionWeakestLine.
  ///
  /// In en, this message translates to:
  /// **'Needs attention: {part}'**
  String adminDecisionWeakestLine(String part);

  /// CTR outcome vs model expectation
  ///
  /// In en, this message translates to:
  /// **'📊 Outcome learning'**
  String get adminDecisionOutcomeTitle;

  /// Explainer
  ///
  /// In en, this message translates to:
  /// **'After send: CTR check at ~6h, full outcome at ~24h (vs expected CTR on the decision log).'**
  String get adminDecisionOutcomeSubtitle;

  /// No description provided for @adminDecisionOutcomeBeat.
  ///
  /// In en, this message translates to:
  /// **'🔥 Beat expectation: {pct}%'**
  String adminDecisionOutcomeBeat(String pct);

  /// No description provided for @adminDecisionOutcomeMiss.
  ///
  /// In en, this message translates to:
  /// **'📉 Below expectation: {pct}%'**
  String adminDecisionOutcomeMiss(String pct);

  /// Empty outcome state
  ///
  /// In en, this message translates to:
  /// **'No completed outcome evaluation yet (needs linked push + time window).'**
  String get adminDecisionOutcomeWaiting;

  /// Dashboard section
  ///
  /// In en, this message translates to:
  /// **'📊 Caption performance'**
  String get adminCaptionPerformanceTitle;

  /// Caption metrics explainer
  ///
  /// In en, this message translates to:
  /// **'Sample: last usage logs + click logs (learning signal for variant scores).'**
  String get adminCaptionPerformanceSubtitle;

  /// One caption variant row
  ///
  /// In en, this message translates to:
  /// **'Variant {variant} → {clicks} clicks · CTR {ctrPercent}%'**
  String adminCaptionPerformanceRow(String variant, int clicks, String ctrPercent);

  /// Caption learning section
  ///
  /// In en, this message translates to:
  /// **'📊 Learning insights'**
  String get adminCaptionLearningTitle;

  /// Learning explainer
  ///
  /// In en, this message translates to:
  /// **'Factor weights used in variant scoring (updated by scheduled job from usage + clicks).'**
  String get adminCaptionLearningSubtitle;

  /// Factor label
  ///
  /// In en, this message translates to:
  /// **'emoji'**
  String get adminCaptionLearningFactorEmoji;

  /// Factor label
  ///
  /// In en, this message translates to:
  /// **'area'**
  String get adminCaptionLearningFactorArea;

  /// Factor label
  ///
  /// In en, this message translates to:
  /// **'urgency'**
  String get adminCaptionLearningFactorUrgency;

  /// Factor label
  ///
  /// In en, this message translates to:
  /// **'short text'**
  String get adminCaptionLearningFactorShort;

  /// Marketing admin hub
  ///
  /// In en, this message translates to:
  /// **'Control center'**
  String get adminControlCenterTitle;

  /// Section
  ///
  /// In en, this message translates to:
  /// **'System status'**
  String get adminControlCenterSystemStatus;

  /// Section
  ///
  /// In en, this message translates to:
  /// **'Trust (auto marketing)'**
  String get adminControlCenterTrust;

  /// Section
  ///
  /// In en, this message translates to:
  /// **'Performance'**
  String get adminControlCenterPerformance;

  /// Section
  ///
  /// In en, this message translates to:
  /// **'Controls'**
  String get adminControlCenterControls;

  /// No description provided for @adminControlCenterAutoModeOn.
  ///
  /// In en, this message translates to:
  /// **'Auto mode: On'**
  String get adminControlCenterAutoModeOn;

  /// No description provided for @adminControlCenterAutoModeOff.
  ///
  /// In en, this message translates to:
  /// **'Auto mode: Off'**
  String get adminControlCenterAutoModeOff;

  /// No description provided for @adminControlCenterShieldActive.
  ///
  /// In en, this message translates to:
  /// **'Shield: Active'**
  String get adminControlCenterShieldActive;

  /// No description provided for @adminControlCenterShieldInactive.
  ///
  /// In en, this message translates to:
  /// **'Shield: Inactive'**
  String get adminControlCenterShieldInactive;

  /// No description provided for @adminControlCenterAvgTrust.
  ///
  /// In en, this message translates to:
  /// **'Avg trust'**
  String get adminControlCenterAvgTrust;

  /// No description provided for @adminControlCenterLastDelta.
  ///
  /// In en, this message translates to:
  /// **'Last outcome Δ'**
  String get adminControlCenterLastDelta;

  /// No description provided for @adminControlCenterLastDeltaNone.
  ///
  /// In en, this message translates to:
  /// **'—'**
  String get adminControlCenterLastDeltaNone;

  /// No description provided for @adminControlCenterCtrTrend.
  ///
  /// In en, this message translates to:
  /// **'CTR trend (recent campaigns)'**
  String get adminControlCenterCtrTrend;

  /// No description provided for @adminControlCenterTotalConversions.
  ///
  /// In en, this message translates to:
  /// **'Total conversions (sample)'**
  String get adminControlCenterTotalConversions;

  /// No description provided for @adminControlCenterBestCaption.
  ///
  /// In en, this message translates to:
  /// **'Best caption (by CTR)'**
  String get adminControlCenterBestCaption;

  /// No description provided for @adminControlCenterBestCaptionValue.
  ///
  /// In en, this message translates to:
  /// **'Variant {variant} · CTR {ctr}'**
  String adminControlCenterBestCaptionValue(String variant, String ctr);

  /// No description provided for @adminControlCenterNoPerformanceData.
  ///
  /// In en, this message translates to:
  /// **'No notification logs yet.'**
  String get adminControlCenterNoPerformanceData;

  /// No description provided for @adminControlCenterResetLearning.
  ///
  /// In en, this message translates to:
  /// **'Reset learning'**
  String get adminControlCenterResetLearning;

  /// No description provided for @adminControlCenterResetLearningTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset learning?'**
  String get adminControlCenterResetLearningTitle;

  /// No description provided for @adminControlCenterResetLearningBody.
  ///
  /// In en, this message translates to:
  /// **'Trust scores, decision counters, shield state, and outcome snapshot on the server will be reset. This cannot be undone.'**
  String get adminControlCenterResetLearningBody;

  /// No description provided for @adminControlCenterDisableShield.
  ///
  /// In en, this message translates to:
  /// **'Disable shield'**
  String get adminControlCenterDisableShield;

  /// No description provided for @adminControlCenterSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get adminControlCenterSaved;

  /// No description provided for @adminControlCenterDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get adminControlCenterDone;

  /// No description provided for @adminControlCenterFailed.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get adminControlCenterFailed;

  /// Control center section
  ///
  /// In en, this message translates to:
  /// **'System alerts'**
  String get adminSystemAlertsTitle;

  /// No description provided for @adminSystemAlertsUnread.
  ///
  /// In en, this message translates to:
  /// **'{count} unread'**
  String adminSystemAlertsUnread(int count);

  /// Empty alerts
  ///
  /// In en, this message translates to:
  /// **'No active alerts.'**
  String get adminSystemAlertsEmpty;

  /// No description provided for @adminSystemAlertsMarkRead.
  ///
  /// In en, this message translates to:
  /// **'Mark read'**
  String get adminSystemAlertsMarkRead;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar': return AppLocalizationsAr();
    case 'en': return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
